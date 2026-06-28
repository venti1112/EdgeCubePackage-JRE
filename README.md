# EdgeCubePackage-JRE

把 [OpenJDK](https://openjdk.org/) 编译成 Android 可用的 JRE，并打包成
EdgeCube 可导入的 `.ecpkg` 运行时包。

本仓库 fork 自 FoldCraftLauncher 的 OpenJDK-Build，按 JRE 主版本分分支管理：

| 分支 | JRE 版本 |
|---|---|
| `JRE8`  | OpenJDK 8  |
| `JRE11` | OpenJDK 11 |
| `JRE17` | OpenJDK 17 |
| `JRE21` | OpenJDK 21 |
| `JRE25` | OpenJDK 25 |

本分支（`JRE21`）用于编译 JRE 21。

本仓库只负责产出 JRE 运行时包。配套的 native 加载器 `liblaunch.so`
由宿主 EdgeCube APK 内置；App 导入 `.ecpkg` 后，运行时会被安装到私有数据
目录，并由加载器 `dlopen` 其中的 `lib/libjli.so` 启动 JVM。

## 原理

- OpenJDK 通过 Android NDK 交叉编译为各 Android ABI（`aarch32`、`aarch64`、
  `x86`、`x86_64`）的 JRE。
- `repack_jre.sh` 把每份 JRE 拆分为架构无关部分（`universal.tar.xz`）与
  架构相关部分（`bin-<arch>.tar.xz`），以减小多架构包的体积。
- `pack_ecpkg.sh` 在 `repack_jre.sh` 之后运行，把拆分后的 tarball 重新组织
  成 `.ecpkg` 包：单架构包把 universal 合并进架构目录；多架构包保留
  `universal/` 目录并在清单中声明 `universalDir`。
- `.ecpkg` 是 ZIP 容器，根目录包含 `edgecube-package.json`，各架构文件
  位于 `arm64/`、`arm/`、`x86_64/` 等目录。
- EdgeCube 导入包时会读取清单，先提取 `universalDir`（若有），再提取
  当前设备架构目录到 `filesDir/runtimes/<id>/`，并写入安装完成标记
  `version`。
- Android API 29+ 禁止从数据目录直接 `execve`，但允许 `dlopen` 其中的
  `.so`，所以 JRE 可以独立于 APK 热更新。

## 目录结构

```text
ci_build_arch_aarch32.sh   单架构编译脚本（32-bit ARM）
ci_build_arch_aarch64.sh   单架构编译脚本（64-bit ARM）
ci_build_arch_x86.sh       单架构编译脚本（32-bit x86）
ci_build_arch_x86_64.sh    单架构编译脚本（64-bit x86）
extract_ndk.sh             解压 NDK（运行一次）
get_boot_jdk.sh            下载引导 JDK
get_libs.sh                下载 CUPS、Freetype 源码
build_libs.sh              构建 Freetype
clone_jdk.sh               克隆 JDK 源码（运行一次）
build_jdk.sh               配置并编译 JDK
remove_jdk_debug_info.sh   去除调试符号
tar_jdk.sh                 打包 JRE tarball
repack_jre.sh              拆分 JRE 为 universal + bin-<arch>
pack_ecpkg.sh              把拆分后的 tarball 打包为 .ecpkg
.github/workflows/build.yml  CI 编译与打包流程
```

## 构建

### 本地构建

前置要求：

- Android NDK r21（**不要**使用更新或更旧的版本，会导致编译失败）
- 引导 JDK 20（构建 JDK 21 时需要）
- `tar` 支持 `-J`（xz）、`zip` 或 `python3` / `python` 作为 ZIP 打包后备

```bash
# Setup NDK, run once
./extract_ndk.sh

# Get boot JDK, JDK 20 is needed when building JDK 21.
./get_boot_jdk.sh

# Get CUPS, Freetype and build Freetype
./get_libs.sh
./build_libs.sh

# Clone JDK, run once
./clone_jdk.sh

# Configure JDK and build
./build_jdk.sh

# Strip debug info and pack tarballs
./remove_jdk_debug_info.sh
./tar_jdk.sh

# Repack into universal + bin-<arch> split
./repack_jre.sh <path_to_jre_tarballs> <multiarch_output_dir>

# Pack .ecpkg packages
./pack_ecpkg.sh <multiarch_output_dir> <ecpkg_output_dir>
```

可选环境变量：

```bash
export BUILD_FREETYPE_VERSION=[2.6.2/.../2.10.0] # default: 2.10.0
export JDK_DEBUG_LEVEL=[release/fastdebug/slowdebug] # default: release
export JVM_VARIANTS=[client/server] # default: server
```

### GitHub Actions

推送到任意分支或发起 PR 时，`.github/workflows/build.yml` 会自动：

1. 在矩阵任务中为 `aarch32` / `aarch64` / `x86` / `x86_64` 四个 ABI 分别
   编译 JRE tarball。
2. 在 `fcl` 任务中下载所有架构的 tarball，运行 `repack_jre.sh` 拆分为
   universal + bin-<arch>。
3. 运行 `pack_ecpkg.sh` 生成 `.ecpkg` 包。
4. 上传三个 artifact：
   - `jre21-<arch>`：单架构 JRE tarball（编译产物）
   - `jre21-multiarch`：拆分后的 universal + bin-<arch>
   - `jre21-ecpkg`：最终 `.ecpkg` 包

### pack_ecpkg.sh 用法

```bash
./pack_ecpkg.sh [input_dir] [output_dir]
```

- `input_dir`：`repack_jre.sh` 的输出目录，需包含 `universal.tar.xz`、
  `bin-arm64.tar.xz`、`bin-arm.tar.xz`、`bin-x86_64.tar.xz`。
- `output_dir`：`.ecpkg` 输出目录，默认为 `<input_dir>/ecpkg`。

环境变量：

| 变量 | 默认值 | 说明 |
|---|---|---|
| `ECPKG_ID` | `jre21` | 运行时 id，会作为 EdgeCube 的安装目录名 |
| `ECPKG_NAME` | `OpenJDK 21` | 运行时显示名称 |
| `ECPKG_AUTHOR` | `EdgeCube` | 包作者 |
| `ECPKG_HOMEPAGE` | `https://openjdk.org/` | 主页 URL |
| `ECPKG_REPOSITORY` | `https://github.com/venti1112/EdgeCubePackage-JRE` | 仓库地址 |
| `ECPKG_MIN_APP_VERSION` | `6` | 最低 EdgeCube `versionCode` |
| `ECPKG_DESCRIPTION` | `OpenJDK 21 runtime for EdgeCube.` | 包描述 |

> **关于 x86**：`.ecpkg` 规范只支持 `arm64`、`arm`、`x86_64` 三个架构
> 标识符，**不支持** `x86`。即使 `repack_jre.sh` 会产出 `bin-x86.tar.xz`，
> `pack_ecpkg.sh` 也会忽略它，不会生成 `x86` 的 `.ecpkg`。

## 产物

```text
<output_dir>/
  jre21-arm64.ecpkg     单架构包（universal 合并进 arm64/）
  jre21-arm.ecpkg       单架构包
  jre21-x86_64.ecpkg    单架构包
  jre21-multi.ecpkg     多架构包（universal/ + 各架构目录）
```

单架构包内部布局（以 `jre21-arm64.ecpkg` 为例）：

```text
edgecube-package.json
arm64/
  bin/
    java
  lib/
    libjli.so
    libjava.so
    server/
      libjvm.so
    security/
      cacerts
  conf/
  legal/
  release
```

多架构包内部布局：

```text
edgecube-package.json
universal/
  conf/
  lib/security/cacerts
  legal/
arm64/
  bin/java
  lib/libjli.so
  lib/server/libjvm.so
  release
arm/
  bin/java
  lib/libjli.so
  lib/server/libjvm.so
  release
x86_64/
  bin/java
  lib/libjli.so
  lib/server/libjvm.so
  release
```

`edgecube-package.json` 使用 `type: "jre"`，启动器配置为：

```json
{
  "launcher": {
    "type": "jli",
    "lib": "lib/libjli.so"
  },
  "env": {
    "JAVA_HOME": "${RUNTIME_DIR}",
    "PATH": "${RUNTIME_DIR}/bin"
  }
}
```

`version` 字段从 JRE `release` 文件的 `JAVA_VERSION` 字段提取
（如 `21.0.1+12`），解析失败时回退到 `repack_jre.sh` 写入的 `version`
文件。

当前包清单不写入 `updateUrl`，因为 EdgeCube 的运行时更新功能尚未实现。

## 接入 App

在 EdgeCube 的“运行环境”页面导入任意 `.ecpkg` 包即可。App 会按设备架构
提取对应目录，安装后目录形态为：

```text
filesDir/runtimes/jre21/
  edgecube-package.json
  version
  bin/
    java
  lib/
    libjli.so
    server/
      libjvm.so
    ...
  conf/
  legal/
  release
```

启动 Minecraft 服务端时，EdgeCube 会执行 APK 内置的 `liblaunch.so`，
通过 `dlopen` 加载运行时目录下的 `lib/libjli.so` 并启动 JVM。

## 许可

OpenJDK 采用 GPL v2 with Classpath Exception 许可，详见
[OpenJDK Assembly Exception](https://openjdk.org/legal/assembly-exception.html)。
