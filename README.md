# rimel — Emacs 里的 Rime 输入法

`rimel` 通过 **librime + 原生 C 动态模块** 在 Emacs 中提供 [Rime（中州韻）](https://rime.im) 输入法。

- **原生 input method**：用 `register-input-method` 注册，经由 `input-method-function` 工作，与内置的 Quail 输入法走同一条路径。**不使用** `post-self-insert-hook` 等插入钩子。组字期间不修改 buffer（预编辑文字是 overlay），所以不会触发 `after-change-functions`、undo 记录或 LSP 同步。上屏文字作为普通按键事件返回，由 `self-insert-command` 插入，`electric-pair`、`abbrev`、键盘宏等照常工作。
- **探针（probes）**：根据光标所处环境自动切换中英文，例如代码里打英文、注释和字符串里打中文。
- **候选框**：可选 posframe（子 frame），也可选原生 minibuffer/echo area，也能交给自定义函数显示。
- **异步、不卡顿**：部署、词库编译、用户数据同步都在 librime 的后台线程中运行，结果经管道进程异步通知 Emacs；每个按键只调用一次模块函数；有待处理输入时跳过候选框渲染。

测试环境为 **Emacs 31.1**（最新 release）和 librime 1.10。

## 依赖

- Emacs 28.1 及以上，编译时启用动态模块（`--with-modules`，各发行版默认开启）。需要 Emacs 28 的 `open_channel` 模块 API。
- librime 开发文件（≥ 1.8）与至少一套 Rime 方案数据。
- C 编译器、`make`、`pkg-config`。
- 可选：[posframe](https://github.com/tumashu/posframe)（图形界面下使用子 frame 候选框）。

| 系统 | 安装命令 |
| --- | --- |
| Debian / Ubuntu | `sudo apt install librime-dev rime-data-luna-pinyin` |
| Arch | `sudo pacman -S librime rime-luna-pinyin` |
| macOS (Homebrew) | `brew install librime`，方案数据可用 [plum](https://github.com/rime/plum) 安装 |

其他系统请安装 librime 的开发包和至少一个方案的数据包。

## 安装

> **注意重名**：MELPA 上已经有一个同名但完全不同的包 `rimel`（[emacs-rime/rimel](https://github.com/emacs-rime/rimel)）。一句普通的 `(use-package rimel)`，配合 `:ensure t` 或 `use-package-always-ensure`，装到的会是那个包。安装本项目时，必须明确告诉 use-package 从这个仓库安装，或者不要让它去包仓库下载。

### use-package + `:vc`（Emacs 30+）

```elisp
(use-package rimel
  :vc (:url "https://github.com/Tao-Boy/rimel" :rev :newest)
  :custom
  (default-input-method "rimel"))
```

有 `:vc` 时 use-package 不会再执行 `:ensure`，即使设置了 `use-package-always-ensure` 也不会去 MELPA 下载。以后 `package-upgrade-all` 也不会用 MELPA 的同名包替换它。

**如果之前已经装过 MELPA 的 `rimel`**，`:vc` 发现已有同名包就会直接跳过，继续使用那个包。先删掉它再重启 Emacs：

```
M-x package-delete RET rimel-<版本号> RET
```

（或者直接删除 `~/.emacs.d/elpa/rimel-<版本号>/` 目录。`elpa/rimel/` 不带版本号，是 `:vc` 安装的本项目。）

### Emacs 29

Emacs 29 的 use-package 还没有 `:vc`，先手动安装一次：

```
M-x package-vc-install RET https://github.com/Tao-Boy/rimel RET
```

然后用 `:ensure nil` 阻止 use-package 去包仓库下载：

```elisp
(use-package rimel
  :ensure nil
  :custom
  (default-input-method "rimel"))
```

### 手动 clone

```sh
git clone https://github.com/Tao-Boy/rimel ~/.emacs.d/site-lisp/rimel
cd ~/.emacs.d/site-lisp/rimel && make
```

```elisp
(use-package rimel
  :ensure nil                                ; 不从包仓库下载
  :load-path "~/.emacs.d/site-lisp/rimel"
  :custom
  (default-input-method "rimel"))
```

（有 `:load-path` 时 `use-package-always-ensure` 不生效，但写上 `:ensure nil` 更明确。不用 use-package 的话：`(add-to-list 'load-path "~/.emacs.d/site-lisp/rimel")`，再 `(require 'rimel)`。）

### straight.el / elpaca

这两者默认按包名去找 MELPA 的配方，同样会拿到同名的那个包。需要显式写出配方，并且把 C 源码和 Makefile 也包含进来，否则无法编译模块：

```elisp
;; straight.el
(use-package rimel
  :straight (:host github :repo "Tao-Boy/rimel"
             :files ("*.el" "rimel-module.c" "Makefile")))

;; elpaca
(use-package rimel
  :ensure (:host github :repo "Tao-Boy/rimel"
           :files ("*.el" "rimel-module.c" "Makefile")))
```

### 确认装对了

```elisp
(locate-library "rimel")   ; 应指向本仓库的 rimel.el
(fboundp 'rimel-compile-module)   ; 本项目才有，应为 t
```

首次激活时，如果模块还没编译，rimel 会询问是否编译。编译通过 `make` 在后台进程中完成，不会卡住 Emacs。也可以随时 `M-x rimel-compile-module`。

编译参数：

```sh
make EMACS=/path/to/emacs              # 用该 Emacs 定位 emacs-module.h
make EMACS_INCLUDE_DIR=/path/include   # 直接指定 emacs-module.h 所在目录
make LIBRIME_ROOT=/opt/librime         # 使用安装在某前缀下的 librime
```

对应的 Elisp 变量是 `rimel-emacs-module-header-root` 和 `rimel-librime-root`。

### Nix / NixOS

Makefile 会自动处理下面两种情况，`M-x rimel-compile-module` 和直接 `make` 都一样：

- **Emacs 来自 Nix**（例如 Debian + Nix 装的 Emacs）：发行版的 librime 加载不进 Nix 的 Emacs 进程。Nix 的动态链接器不搜索 `/usr/lib`，就算加了 rpath，`libglog`、`libstdc++` 等依赖也找不到或互不兼容。这时即使 apt 装了 librime-dev，也会改用 Nix 的 librime。
- **NixOS**：没有全局的 `/usr/include`，pkg-config 和编译器都找不到 librime。

以上两种情况都会执行 `nix-build '<nixpkgs>' -A librime -o .nix-librime`；如果 `NIX_PATH` 里没有 nixpkgs，就改用 flake：`nix build nixpkgs#librime`。生成的 `.nix-librime` 链接是一个 GC root，模块的 rpath 也指向它，所以 `nix-collect-garbage` 不会删掉模块要用的 librime。（相比之下，`nix-shell -p librime` 或 `--no-out-link` 拿到的路径没有 GC root，清理之后模块就加载不了了。）`make distclean` 会删除这些链接。

方案数据（`rime-data`）只是 YAML 和词典，与 librime 版本无关，所以 apt 装的 `/usr/share/rime-data` 可以直接用。rimel 也会查找 `/run/current-system/sw`、`/etc/profiles/per-user/$USER`、`~/.nix-profile`、`~/.local/state/nix/profile` 下的 `share/rime-data`。哪里都找不到、但系统里有 Nix 时，激活输入法会在后台执行 `make nix-rime-data`（链接为 `.nix-rime-data`）。

想用别的 librime，可以显式指定：`(setq rimel-librime-root "/nix/store/...-librime-1.x")`，或者 `make LIBRIME_ROOT=...`。

## 使用

`C-\`（`toggle-input-method`）开关输入法。组字期间：

| 按键 | 作用 |
| --- | --- |
| `SPC` / 数字 | 上屏首选 / 第 N 个候选 |
| `RET` | 上屏原始编码 |
| `DEL`、`C-h` | 删除编码 |
| `<up>` `<down>`、`C-p` `C-n` | 移动高亮（Rime 默认 key_binder 提供 Emacs 风格键位） |
| `-` `=`、`<prior>` `<next>`、`M-v` `C-v` | 翻页 |
| `<escape>`、`C-g` | 取消组字 |
| 其他 Rime 不处理的键（如 `C-x`） | 按 `rimel-interrupt-action` 处理组字，然后照常执行该键 |

Emacs 只把可打印字符交给 `input-method-function`，所以没有组字时，`F4`、`` C-` `` 这类 Rime 快捷键到不了 Rime：请用 `rimel-select-schema` 切换方案。Emacs 也收不到单独的 Shift 键事件，中英切换请用 `rimel-toggle-ascii-mode` 并自行绑定按键：

```elisp
(global-set-key (kbd "C-c r s") #'rimel-select-schema)
(global-set-key (kbd "C-c r a") #'rimel-toggle-ascii-mode)
(global-set-key (kbd "C-c r f") #'rimel-force-rime)
```

### 命令

| 命令 | 说明 |
| --- | --- |
| `rimel-select-schema` | 选择输入方案 |
| `rimel-toggle-ascii-mode` | 切换 Rime 的西文模式 |
| `rimel-force-rime` | 下一次输入忽略探针，强制使用 Rime |
| `rimel-deploy` | 修改配置后在后台重新部署 |
| `rimel-sync` | 在后台同步用户词库 |
| `rimel-open-user-dir` | 打开用户目录（在这里放 `default.custom.yaml` 等） |
| `rimel-compile-module` | 在后台编译模块 |
| `rimel-restart` | 重启 librime |

## 配置

### 探针：按光标环境自动切换

`rimel-probes` 是探针函数列表。只在**即将开始新的组字**时询问探针，组字过程中不会询问。每个探针无参数调用，调用时 `rimel-probe-key` 绑定为当前按键。第一个返回非 nil 的探针决定结果：

- 返回 `rime`：交给 Rime；
- 返回其他非 nil 值：原样插入按键（英文）；
- 全部返回 nil：交给 Rime。

普通谓词可以直接当探针用：返回 t 即表示“这里打英文”。

```elisp
(setq-default rimel-probes
              '(rimel-probe-after-cjk           ; 紧跟汉字：继续中文（返回 rime）
                rimel-probe-program             ; 代码中英文，注释/字符串中中文
                rimel-probe-org                 ; Org 源码块与 LaTeX 片段
                rimel-probe-tex-math            ; TeX 数学环境
                rimel-probe-after-alphanumeric  ; 紧跟英文字母或数字
                rimel-probe-punctuation-after-ascii
                rimel-probe-uppercase           ; 大写字母开头打英文
                rimel-probe-evil-non-insert
                rimel-probe-meow-non-insert))

;; 也可以 buffer-local 设置，或写自己的探针：
(defun my-probe-markdown-code ()
  "Markdown 代码块里打英文。"
  (and (derived-mode-p 'markdown-mode)
       (fboundp 'markdown-code-block-at-point-p)
       (markdown-code-block-at-point-p)))
(add-to-list 'rimel-probes #'my-probe-markdown-code)
```

内置探针：`rimel-probe-program`、`rimel-probe-after-alphanumeric`、`rimel-probe-after-ascii`、`rimel-probe-uppercase`、`rimel-probe-punctuation-after-ascii`、`rimel-probe-after-cjk`、`rimel-probe-org`、`rimel-probe-tex-math`、`rimel-probe-minibuffer`、`rimel-probe-evil-non-insert`、`rimel-probe-meow-non-insert`。

需要临时在代码里打中文时，用 `M-x rimel-force-rime`（建议绑定按键）。

### 模式行指示器

```elisp
(setq rimel-indicator-refresh t)   ; 光标移动时及时刷新（只读状态，不插入文字）
(add-to-list 'mode-line-misc-info '(:eval (rimel-indicator)))
```

按键交给 Rime 时显示 `rimel-title`（默认 “ㄓ”），因西文模式或探针而打英文时显示灰色的 “A”。

### 候选框

```elisp
(setq rimel-candidate-style 'posframe)    ; posframe | minibuffer | nil | 函数
(setq rimel-candidate-layout 'vertical)   ; posframe 中竖排
(setq rimel-inline-preedit 'raw)          ; 光标处显示：raw 编码 | preview 预上屏文字 | nil
(setq rimel-posframe-properties
      '(:internal-border-width 2 :left-fringe 6 :right-fringe 6))
```

- `posframe`：在光标旁的子 frame 中显示。没有 posframe 包或处于终端时自动退回 `minibuffer`。
- `minibuffer`：显示在 echo area。在活动的 minibuffer 里输入时，候选接在预编辑文字之后显示。
- 自定义函数：以 state 向量调用来显示，以 nil 调用来隐藏；可以用 `rimel-format-candidates` 生成文字。

外观由这些 face 控制：`rimel-preedit-face`、`rimel-code-face`、`rimel-candidate-face`、`rimel-highlight-face`、`rimel-label-face`、`rimel-comment-face`、`rimel-posframe-face`、`rimel-posframe-border-face`。

### 其他选项

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `rimel-shared-data-dir` | 自动探测 | Rime 共享数据目录（如 `/usr/share/rime-data`） |
| `rimel-user-data-dir` | `~/.emacs.d/rime/` | 用户目录，放自定义配置和用户词库 |
| `rimel-log-dir` | 用户目录下的 `log` | librime 日志目录 |
| `rimel-interrupt-action` | `clear` | 组字被打断时：`clear` 丢弃 / `commit` 上屏转换结果 / `commit-raw` 上屏原始编码 |
| `rimel-candidate-labels` | `1`…`0` | 方案未定义选字键时使用的标签 |
| `rimel-deployed-hook` | nil | 后台部署完成后运行 |
| `rimel-verbose` | t | 是否在 echo area 提示部署进度 |

Rime 的配置写在 `rimel-user-data-dir` 中，例如 `default.custom.yaml`：

```yaml
patch:
  schema_list:
    - schema: luna_pinyin_simp
  menu/page_size: 7
```

修改后执行 `M-x rimel-deploy`。部署在后台进行，期间按键按英文原样插入，Emacs 不会卡住。

## 设计

```
按键 ─▶ read_char ─▶ input-method-function = rimel-input-method
                       │  探针（仅在组字开始时） ──▶ 英文：(list key)
                       ▼
                 rimel--compose 组字循环（read-key 读后续按键）
                       │  每键一次 rimel-module-process-key ──▶ librime
                       │  ◀── 一个 state 向量（上屏/预编辑/光标/候选页…）
                       │  预编辑：overlay；候选：posframe / echo area
                       ▼
                 返回上屏文字的字符事件 ─▶ self-insert-command

librime 维护线程（部署/编译词库/同步） ─▶ 非阻塞管道（open_channel）
                                         ─▶ 管道进程 filter（异步）
```

- **一次往返**：`rimel-module-process-key` 送入按键后，在同一次 C 调用中取回提交文字、预编辑、光标、候选页、标签、西文模式等，打包成一个向量返回。UTF-8 字节偏移也在 C 里换算成字符下标。
- **后台部署**：`rimel-module-start` 调用 librime 的 `start_maintenance` 后立即返回（实测约 13 ms），部署在 librime 线程中完成。librime 的通知回调可能来自任意线程，回调里只做一次 `write(2)`，写入 `open_channel` 取得的非阻塞管道，**从不在主线程之外调用 Emacs API**。维护期间所有入口立即返回 nil，按键按原样插入。
- **渲染节流**：处理按键后如果还有待读输入（`input-pending-p`），就跳过候选框渲染，快速连续输入时不会被 posframe 拖慢。候选内容和位置都没变时（例如在编码中移动光标），不再调用 `posframe-show`。
- **顶字上屏**：遇到“上屏的同时留下新组字”的情况（如五笔顶字），先把上屏文字交还命令循环，剩余编码以 `(no-record . KEY)` 重新送入输入法。这样键盘宏不会重复记录，探针也不会打断。

性能（Emacs 31.1 + librime 1.10，luna_pinyin，Linux x86-64）：

| 项目 | 耗时 |
| --- | --- |
| 模块内处理一个按键并取回完整状态 | 约 40–55 µs |
| 经过完整命令循环（`read_char` → 输入法 → `self-insert-command`） | 约 150 µs/键 |
| 预编辑 overlay 更新加一次重绘（GTK3 图形界面） | 约 90–150 µs |
| `posframe-show` 加一次重绘（GTK3 图形界面） | 约 1.8 ms |
| `rimel-module-start`（部署在后台进行） | 约 13 ms |

## 测试

```sh
make test          # 编译模块、字节编译（警告视为错误）并运行 ERT
make test EMACS=/opt/emacs-31.1/bin/emacs
```

集成测试用键盘宏驱动真实的命令循环，按键经过 `read_char → input-method-function → read-key`，与实际打字的路径相同。测试使用 `test/tmp` 下的临时用户目录和一个自带的小码表方案（`test/data`）来覆盖顶字上屏。

## 许可

MIT
