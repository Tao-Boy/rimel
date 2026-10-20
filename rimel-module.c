/* rimel-module.c --- Emacs dynamic module binding librime  -*- c-basic-offset: 2 -*-

   Copyright (C) 2026 Tau

   SPDX-License-Identifier: MIT

   This module is a thin, allocation-light bridge between Emacs and the
   librime C API.  Design notes:

   - Every key press costs exactly one module call: `rimel-module-process-key'
     feeds the key to librime and returns the whole resulting state (commit
     text, preedit, caret, candidate page, ...) as one vector, so the Lisp
     side never needs a second round trip to render.

   - Slow work (deployment, dictionary compilation, user data sync) runs in
     librime's own maintenance thread.  librime's notifications are written
     from whatever thread produced them to a non-blocking pipe obtained with
     `open_channel', so they reach Emacs asynchronously through a pipe
     process filter.  No Emacs API is ever touched off the main thread.

   - While librime is in maintenance mode, every entry point returns nil
     immediately instead of waiting for the maintenance thread.  */

#include <emacs-module.h>
#include <rime_api.h>

#include <errno.h>
#include <fcntl.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int plugin_is_GPL_compatible;

#define RIMEL_MODULE_VERSION "0.1.0"

static RimeApi *rime;
static RimeSessionId session;
static bool rime_setup_done;
static bool rime_started;
static int notify_fd = -1;

static char *shared_dir;
static char *user_dir;
static char *log_dir;

/* Global references, created once in emacs_module_init.  */
static emacs_value Qnil, Qt, Qlist, Qcons, Qvector, Qerror;

/* Number of slots in the state vector; keep in sync with rimel.el.  */
enum
{
  ST_HANDLED,
  ST_COMMIT,
  ST_INPUT,
  ST_PREEDIT,
  ST_CURSOR,
  ST_SEL_START,
  ST_SEL_END,
  ST_CANDIDATES,
  ST_HIGHLIGHTED,
  ST_PAGE_NO,
  ST_LAST_PAGE_P,
  ST_LABELS,
  ST_PREVIEW,
  ST_ASCII_MODE,
  ST_SIZE
};

/* ------------------------------------------------------------------ */
/* Small helpers.  */

static inline bool
nilp (emacs_env *env, emacs_value v)
{
  return !env->is_not_nil (env, v);
}

static inline emacs_value
bool_value (bool b)
{
  return b ? Qt : Qnil;
}

static emacs_value
make_cstring (emacs_env *env, const char *s)
{
  if (!s)
    return Qnil;
  return env->make_string (env, s, (ptrdiff_t) strlen (s));
}

static emacs_value
make_nstring (emacs_env *env, const char *s, size_t len)
{
  return env->make_string (env, s, (ptrdiff_t) len);
}

/* Return a malloc'ed copy of the Lisp string V, or NULL on failure (in
   which case a non-local exit is pending).  */
static char *
copy_lisp_string (emacs_env *env, emacs_value v)
{
  ptrdiff_t size = 0;
  if (!env->copy_string_contents (env, v, NULL, &size))
    return NULL;
  char *buf = malloc ((size_t) size);
  if (!buf)
    {
      env->non_local_exit_signal (env, Qerror, Qnil);
      return NULL;
    }
  if (!env->copy_string_contents (env, v, buf, &size))
    {
      free (buf);
      return NULL;
    }
  return buf;
}

static emacs_value
signal_error (emacs_env *env, const char *msg)
{
  emacs_value data = make_cstring (env, msg);
  emacs_value args = env->funcall (env, Qlist, 1, &data);
  env->non_local_exit_signal (env, Qerror, args);
  return Qnil;
}

/* Number of UTF-8 code points in the first BYTES bytes of S.  */
static intmax_t
utf8_chars (const char *s, int bytes)
{
  intmax_t n = 0;
  if (!s || bytes <= 0)
    return 0;
  for (int i = 0; i < bytes && s[i]; i++)
    if (((unsigned char) s[i] & 0xC0) != 0x80)
      n++;
  return n;
}

static bool
ready (void)
{
  return rime_started && !rime->is_maintenance_mode ();
}

/* Make sure a live session exists.  Sessions are dropped by librime
   whenever it redeploys, so check on every use (a hash lookup).  */
static bool
ensure_session (void)
{
  if (!ready ())
    return false;
  if (session && rime->find_session (session))
    return true;
  session = rime->create_session ();
  return session != 0;
}

/* ------------------------------------------------------------------ */
/* Notifications: called from librime threads, so only write(2) here.  */

static void
notification_handler (void *ctx, RimeSessionId sid, const char *type,
                      const char *value)
{
  (void) ctx;
  (void) sid;
  int fd = notify_fd;
  if (fd < 0 || !type)
    return;
  char buf[512];
  int n = snprintf (buf, sizeof buf, "%s\t%s\n", type, value ? value : "");
  if (n <= 0)
    return;
  if ((size_t) n >= sizeof buf)
    {
      n = sizeof buf - 1;
      buf[n - 1] = '\n';
    }
  /* A single write below PIPE_BUF is atomic, so concurrent notifications
     never interleave.  The fd is non-blocking: if Emacs is not draining
     the pipe we drop the message instead of stalling the caller.  */
  ssize_t r;
  do
    r = write (fd, buf, (size_t) n);
  while (r < 0 && errno == EINTR);
}

/* ------------------------------------------------------------------ */
/* State snapshot.  */

static emacs_value
build_state (emacs_env *env, bool handled)
{
  emacs_value st[ST_SIZE];
  for (int i = 0; i < ST_SIZE; i++)
    st[i] = Qnil;
  st[ST_HANDLED] = bool_value (handled);

  RIME_STRUCT (RimeCommit, commit);
  if (rime->get_commit (session, &commit))
    {
      if (commit.text && commit.text[0])
        st[ST_COMMIT] = make_cstring (env, commit.text);
      rime->free_commit (&commit);
    }

  RIME_STRUCT (RimeContext, ctx);
  if (rime->get_context (session, &ctx))
    {
      if (ctx.composition.length > 0 && ctx.composition.preedit)
        {
          const char *p = ctx.composition.preedit;
          st[ST_PREEDIT] = make_cstring (env, p);
          st[ST_CURSOR] = env->make_integer
            (env, utf8_chars (p, ctx.composition.cursor_pos));
          st[ST_SEL_START] = env->make_integer
            (env, utf8_chars (p, ctx.composition.sel_start));
          st[ST_SEL_END] = env->make_integer
            (env, utf8_chars (p, ctx.composition.sel_end));
          const char *input = rime->get_input (session);
          if (input)
            st[ST_INPUT] = make_cstring (env, input);
        }

      int n = ctx.menu.num_candidates;
      if (n > 0 && ctx.menu.candidates)
        {
          emacs_value items[n];
          emacs_value labels[n];
          bool have_labels = false;
          const char *keys = ctx.menu.select_keys;
          size_t nkeys = keys ? strlen (keys) : 0;
          char **slabels = NULL;
          if (RIME_STRUCT_HAS_MEMBER (ctx, ctx.select_labels))
            slabels = ctx.select_labels;
          for (int i = 0; i < n; i++)
            {
              RimeCandidate *c = &ctx.menu.candidates[i];
              emacs_value pair[2];
              pair[0] = make_cstring (env, c->text ? c->text : "");
              pair[1] = (c->comment && c->comment[0])
                ? make_cstring (env, c->comment) : Qnil;
              items[i] = env->funcall (env, Qcons, 2, pair);
              if (slabels && slabels[i])
                {
                  labels[i] = make_cstring (env, slabels[i]);
                  have_labels = true;
                }
              else if ((size_t) i < nkeys)
                {
                  labels[i] = make_nstring (env, keys + i, 1);
                  have_labels = true;
                }
              else
                labels[i] = Qnil;
            }
          st[ST_CANDIDATES] = env->funcall (env, Qlist, n, items);
          if (have_labels)
            st[ST_LABELS] = env->funcall (env, Qlist, n, labels);
          st[ST_HIGHLIGHTED] = env->make_integer
            (env, ctx.menu.highlighted_candidate_index);
          st[ST_PAGE_NO] = env->make_integer (env, ctx.menu.page_no);
          st[ST_LAST_PAGE_P] = bool_value (ctx.menu.is_last_page);
        }

      if (RIME_STRUCT_HAS_MEMBER (ctx, ctx.commit_text_preview)
          && ctx.commit_text_preview)
        st[ST_PREVIEW] = make_cstring (env, ctx.commit_text_preview);
      rime->free_context (&ctx);
    }

  st[ST_ASCII_MODE] = bool_value (rime->get_option (session, "ascii_mode"));
  return env->funcall (env, Qvector, ST_SIZE, st);
}

/* ------------------------------------------------------------------ */
/* Lifecycle.  */

static void
replace_string (char **slot, char *value)
{
  free (*slot);
  *slot = value;
}

static emacs_value
Frimel_module_start (emacs_env *env, ptrdiff_t nargs, emacs_value *args,
                     void *data)
{
  (void) data;
  char *shared = copy_lisp_string (env, args[0]);
  if (!shared)
    return Qnil;
  char *user = copy_lisp_string (env, args[1]);
  if (!user)
    {
      free (shared);
      return Qnil;
    }
  char *logd = NULL;
  if (nargs > 2 && !nilp (env, args[2]))
    {
      logd = copy_lisp_string (env, args[2]);
      if (!logd)
        {
          free (shared);
          free (user);
          return Qnil;
        }
    }
  int fd = -1;
  if (nargs > 3 && !nilp (env, args[3]))
    {
      if ((size_t) env->size < sizeof (struct emacs_env_28))
        {
          free (shared);
          free (user);
          free (logd);
          return signal_error (env, "Emacs 28 or later is required");
        }
      fd = env->open_channel (env, args[3]);
      if (env->non_local_exit_check (env) != emacs_funcall_exit_return)
        {
          free (shared);
          free (user);
          free (logd);
          return Qnil;
        }
      int flags = fcntl (fd, F_GETFL);
      if (flags >= 0)
        fcntl (fd, F_SETFL, flags | O_NONBLOCK);
    }
  bool full_check = nargs > 4 && !nilp (env, args[4]);

  if (rime_started)
    {
      rime->join_maintenance_thread ();
      rime->finalize ();
      rime_started = false;
      session = 0;
    }
  if (notify_fd >= 0 && notify_fd != fd)
    close (notify_fd);
  notify_fd = fd;

  replace_string (&shared_dir, shared);
  replace_string (&user_dir, user);
  replace_string (&log_dir, logd);

  RIME_STRUCT (RimeTraits, traits);
  traits.shared_data_dir = shared_dir;
  traits.user_data_dir = user_dir;
  traits.distribution_name = "Rimel";
  traits.distribution_code_name = "rimel";
  traits.distribution_version = RIMEL_MODULE_VERSION;
  traits.app_name = "rime.rimel";
  traits.min_log_level = 2;
  traits.log_dir = log_dir ? log_dir : "";

  /* librime's setup (logging, module registry) may only run once per
     process; initialize/finalize can be repeated.  */
  if (!rime_setup_done)
    {
      rime->setup (&traits);
      rime_setup_done = true;
    }
  rime->set_notification_handler (notification_handler, NULL);
  rime->initialize (&traits);
  rime_started = true;
  /* Returns immediately; deployment, if needed, runs in librime's
     maintenance thread and reports through the notification pipe.  */
  bool deploying = rime->start_maintenance (full_check ? True : False);
  return env->make_integer (env, deploying ? 1 : 0);
}

static emacs_value
Frimel_module_finalize (emacs_env *env, ptrdiff_t nargs, emacs_value *args,
                        void *data)
{
  (void) env; (void) nargs; (void) args; (void) data;
  if (rime_started)
    {
      /* A deployment in flight must finish before tearing down.  */
      rime->join_maintenance_thread ();
      rime->finalize ();
      rime_started = false;
      session = 0;
    }
  if (notify_fd >= 0)
    {
      close (notify_fd);
      notify_fd = -1;
    }
  return Qt;
}

static emacs_value
Frimel_module_started_p (emacs_env *env, ptrdiff_t nargs, emacs_value *args,
                         void *data)
{
  (void) env; (void) nargs; (void) args; (void) data;
  return bool_value (rime_started);
}

static emacs_value
Frimel_module_maintenance_p (emacs_env *env, ptrdiff_t nargs,
                             emacs_value *args, void *data)
{
  (void) env; (void) nargs; (void) args; (void) data;
  return bool_value (rime_started && rime->is_maintenance_mode ());
}

static emacs_value
Frimel_module_deploy (emacs_env *env, ptrdiff_t nargs, emacs_value *args,
                      void *data)
{
  (void) env; (void) nargs; (void) args; (void) data;
  if (!ready ())
    return Qnil;
  rime->cleanup_all_sessions ();
  session = 0;
  return bool_value (rime->start_maintenance (True));
}

static emacs_value
Frimel_module_sync_user_data (emacs_env *env, ptrdiff_t nargs,
                              emacs_value *args, void *data)
{
  (void) env; (void) nargs; (void) args; (void) data;
  if (!ready ())
    return Qnil;
  session = 0;
  return bool_value (rime->sync_user_data ());
}

/* ------------------------------------------------------------------ */
/* Input.  */

static emacs_value
Frimel_module_process_key (emacs_env *env, ptrdiff_t nargs,
                           emacs_value *args, void *data)
{
  (void) data;
  intmax_t keycode = env->extract_integer (env, args[0]);
  intmax_t mask = nargs > 1 ? env->extract_integer (env, args[1]) : 0;
  if (env->non_local_exit_check (env) != emacs_funcall_exit_return)
    return Qnil;
  if (!ensure_session ())
    return Qnil;
  bool handled = rime->process_key (session, (int) keycode, (int) mask);
  return build_state (env, handled);
}

static emacs_value
Frimel_module_state (emacs_env *env, ptrdiff_t nargs, emacs_value *args,
                     void *data)
{
  (void) nargs; (void) args; (void) data;
  if (!ensure_session ())
    return Qnil;
  return build_state (env, true);
}

static emacs_value
Frimel_module_select_candidate (emacs_env *env, ptrdiff_t nargs,
                                emacs_value *args, void *data)
{
  (void) nargs; (void) data;
  intmax_t index = env->extract_integer (env, args[0]);
  if (env->non_local_exit_check (env) != emacs_funcall_exit_return)
    return Qnil;
  if (!ensure_session () || index < 0)
    return Qnil;
  bool ok = rime->select_candidate_on_current_page (session, (size_t) index);
  return build_state (env, ok);
}

static emacs_value
Frimel_module_highlight_candidate (emacs_env *env, ptrdiff_t nargs,
                                   emacs_value *args, void *data)
{
  (void) nargs; (void) data;
  intmax_t index = env->extract_integer (env, args[0]);
  if (env->non_local_exit_check (env) != emacs_funcall_exit_return)
    return Qnil;
  if (!ensure_session () || index < 0)
    return Qnil;
  bool ok = false;
  if (RIME_API_AVAILABLE (rime, highlight_candidate_on_current_page))
    ok = rime->highlight_candidate_on_current_page (session, (size_t) index);
  return build_state (env, ok);
}

static emacs_value
Frimel_module_delete_candidate (emacs_env *env, ptrdiff_t nargs,
                                emacs_value *args, void *data)
{
  (void) nargs; (void) data;
  intmax_t index = env->extract_integer (env, args[0]);
  if (env->non_local_exit_check (env) != emacs_funcall_exit_return)
    return Qnil;
  if (!ensure_session () || index < 0)
    return Qnil;
  bool ok = false;
  if (RIME_API_AVAILABLE (rime, delete_candidate_on_current_page))
    ok = rime->delete_candidate_on_current_page (session, (size_t) index);
  return build_state (env, ok);
}

static emacs_value
Frimel_module_change_page (emacs_env *env, ptrdiff_t nargs,
                           emacs_value *args, void *data)
{
  (void) nargs; (void) data;
  bool backward = !nilp (env, args[0]);
  if (!ensure_session ())
    return Qnil;
  bool ok;
  if (RIME_API_AVAILABLE (rime, change_page))
    ok = rime->change_page (session, backward);
  else
    ok = rime->process_key (session, backward ? 0xff55 : 0xff56, 0);
  return build_state (env, ok);
}

static emacs_value
Frimel_module_clear_composition (emacs_env *env, ptrdiff_t nargs,
                                 emacs_value *args, void *data)
{
  (void) env; (void) nargs; (void) args; (void) data;
  if (!ensure_session ())
    return Qnil;
  rime->clear_composition (session);
  return Qt;
}

/* Commit the current composition as converted text and return it.  */
static emacs_value
Frimel_module_commit_composition (emacs_env *env, ptrdiff_t nargs,
                                  emacs_value *args, void *data)
{
  (void) nargs; (void) args; (void) data;
  if (!ensure_session ())
    return Qnil;
  emacs_value result = Qnil;
  if (rime->commit_composition (session))
    {
      RIME_STRUCT (RimeCommit, commit);
      if (rime->get_commit (session, &commit))
        {
          if (commit.text && commit.text[0])
            result = make_cstring (env, commit.text);
          rime->free_commit (&commit);
        }
    }
  return result;
}

static emacs_value
Frimel_module_input (emacs_env *env, ptrdiff_t nargs, emacs_value *args,
                     void *data)
{
  (void) nargs; (void) args; (void) data;
  if (!ensure_session ())
    return Qnil;
  const char *input = rime->get_input (session);
  return (input && input[0]) ? make_cstring (env, input) : Qnil;
}

/* ------------------------------------------------------------------ */
/* Options and schemas.  */

static emacs_value
Frimel_module_get_option (emacs_env *env, ptrdiff_t nargs, emacs_value *args,
                          void *data)
{
  (void) nargs; (void) data;
  if (!ensure_session ())
    return Qnil;
  char *name = copy_lisp_string (env, args[0]);
  if (!name)
    return Qnil;
  bool v = rime->get_option (session, name);
  free (name);
  return bool_value (v);
}

static emacs_value
Frimel_module_set_option (emacs_env *env, ptrdiff_t nargs, emacs_value *args,
                          void *data)
{
  (void) nargs; (void) data;
  if (!ensure_session ())
    return Qnil;
  char *name = copy_lisp_string (env, args[0]);
  if (!name)
    return Qnil;
  rime->set_option (session, name, nilp (env, args[1]) ? False : True);
  free (name);
  return Qt;
}

static emacs_value
Frimel_module_schema_list (emacs_env *env, ptrdiff_t nargs,
                           emacs_value *args, void *data)
{
  (void) nargs; (void) args; (void) data;
  if (!ready ())
    return Qnil;
  RimeSchemaList list = { 0 };
  if (!rime->get_schema_list (&list))
    return Qnil;
  size_t n = list.size;
  emacs_value result = Qnil;
  if (n > 0)
    {
      emacs_value *items = malloc (n * sizeof (emacs_value));
      if (items)
        {
          for (size_t i = 0; i < n; i++)
            {
              emacs_value pair[2];
              pair[0] = make_cstring (env, list.list[i].schema_id);
              pair[1] = make_cstring (env, list.list[i].name);
              items[i] = env->funcall (env, Qcons, 2, pair);
            }
          result = env->funcall (env, Qlist, (ptrdiff_t) n, items);
          free (items);
        }
    }
  rime->free_schema_list (&list);
  return result;
}

static emacs_value
Frimel_module_current_schema (emacs_env *env, ptrdiff_t nargs,
                              emacs_value *args, void *data)
{
  (void) nargs; (void) args; (void) data;
  if (!ensure_session ())
    return Qnil;
  char buf[256];
  if (!rime->get_current_schema (session, buf, sizeof buf))
    return Qnil;
  return make_cstring (env, buf);
}

static emacs_value
Frimel_module_select_schema (emacs_env *env, ptrdiff_t nargs,
                             emacs_value *args, void *data)
{
  (void) nargs; (void) data;
  if (!ensure_session ())
    return Qnil;
  char *id = copy_lisp_string (env, args[0]);
  if (!id)
    return Qnil;
  bool ok = rime->select_schema (session, id);
  free (id);
  return bool_value (ok);
}

static emacs_value
Frimel_module_version (emacs_env *env, ptrdiff_t nargs, emacs_value *args,
                       void *data)
{
  (void) nargs; (void) args; (void) data;
  emacs_value v[2];
  v[0] = make_cstring (env, RIMEL_MODULE_VERSION);
  v[1] = (RIME_API_AVAILABLE (rime, get_version))
    ? make_cstring (env, rime->get_version ()) : Qnil;
  return env->funcall (env, Qcons, 2, v);
}

/* ------------------------------------------------------------------ */
/* Registration.  */

static void
defun (emacs_env *env, const char *name, ptrdiff_t min, ptrdiff_t max,
       emacs_value (*fn) (emacs_env *, ptrdiff_t, emacs_value *, void *),
       const char *doc)
{
  emacs_value f = env->make_function (env, min, max, fn, doc, NULL);
  emacs_value sym = env->intern (env, name);
  emacs_value args[] = { sym, f };
  env->funcall (env, env->intern (env, "defalias"), 2, args);
}

static emacs_value
global (emacs_env *env, const char *name)
{
  return env->make_global_ref (env, env->intern (env, name));
}

int
emacs_module_init (struct emacs_runtime *runtime)
{
  if ((size_t) runtime->size < sizeof (*runtime))
    return 1;
  emacs_env *env = runtime->get_environment (runtime);
  if ((size_t) env->size < sizeof (struct emacs_env_28))
    return 2;

  rime = rime_get_api ();
  if (!rime)
    return 3;

  Qnil = global (env, "nil");
  Qt = global (env, "t");
  Qlist = global (env, "list");
  Qcons = global (env, "cons");
  Qvector = global (env, "vector");
  Qerror = global (env, "error");

  defun (env, "rimel-module-start", 2, 5, Frimel_module_start,
         "Start librime.\n\n"
         "(rimel-module-start SHARED-DIR USER-DIR &optional LOG-DIR "
         "CHANNEL FULL-CHECK)\n\n"
         "CHANNEL is a pipe process receiving \"TYPE\\tVALUE\\n\" "
         "notifications.\nReturns 1 if a deployment was started in the "
         "background, else 0.");
  defun (env, "rimel-module-finalize", 0, 0, Frimel_module_finalize,
         "Shut librime down.");
  defun (env, "rimel-module-started-p", 0, 0, Frimel_module_started_p,
         "Return non-nil if librime has been started.");
  defun (env, "rimel-module-maintenance-p", 0, 0,
         Frimel_module_maintenance_p,
         "Return non-nil while librime is deploying in the background.");
  defun (env, "rimel-module-deploy", 0, 0, Frimel_module_deploy,
         "Start a full redeployment in the background.");
  defun (env, "rimel-module-sync-user-data", 0, 0,
         Frimel_module_sync_user_data,
         "Start syncing user data in the background.");
  defun (env, "rimel-module-process-key", 1, 2, Frimel_module_process_key,
         "Send KEYCODE with MASK to librime and return the new state.\n\n"
         "(rimel-module-process-key KEYCODE &optional MASK)\n\n"
         "Returns nil if librime is not ready.");
  defun (env, "rimel-module-state", 0, 0, Frimel_module_state,
         "Return the current state vector.");
  defun (env, "rimel-module-select-candidate", 1, 1,
         Frimel_module_select_candidate,
         "Select candidate INDEX on the current page and return the state.");
  defun (env, "rimel-module-highlight-candidate", 1, 1,
         Frimel_module_highlight_candidate,
         "Highlight candidate INDEX on the current page and return the "
         "state.");
  defun (env, "rimel-module-delete-candidate", 1, 1,
         Frimel_module_delete_candidate,
         "Delete user phrase INDEX on the current page and return the "
         "state.");
  defun (env, "rimel-module-change-page", 1, 1, Frimel_module_change_page,
         "Go to the previous page if BACKWARD, else the next; return the "
         "state.");
  defun (env, "rimel-module-clear-composition", 0, 0,
         Frimel_module_clear_composition, "Discard the composition.");
  defun (env, "rimel-module-commit-composition", 0, 0,
         Frimel_module_commit_composition,
         "Commit the composition and return the committed text.");
  defun (env, "rimel-module-input", 0, 0, Frimel_module_input,
         "Return the raw input string of the composition.");
  defun (env, "rimel-module-get-option", 1, 1, Frimel_module_get_option,
         "Return the value of the boolean option NAME.");
  defun (env, "rimel-module-set-option", 2, 2, Frimel_module_set_option,
         "Set the boolean option NAME to VALUE.");
  defun (env, "rimel-module-schema-list", 0, 0, Frimel_module_schema_list,
         "Return the schema list as ((ID . NAME) ...).");
  defun (env, "rimel-module-current-schema", 0, 0,
         Frimel_module_current_schema, "Return the current schema id.");
  defun (env, "rimel-module-select-schema", 1, 1,
         Frimel_module_select_schema, "Select schema ID.");
  defun (env, "rimel-module-version", 0, 0, Frimel_module_version,
         "Return (MODULE-VERSION . LIBRIME-VERSION).");

  emacs_value feature = env->intern (env, "rimel-module");
  env->funcall (env, env->intern (env, "provide"), 1, &feature);
  return 0;
}
