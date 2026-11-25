// 可单独下载的运行时组件描述。
//
// 这些组件体积大、又只在特定源类型下才用得到（JRE 只有 `csp_` / dex 蜘蛛需要，
// Python 只有 `.py` 源需要……），打进安装包等于让所有用户替少数场景买单，
// 因此改为应用内按需下载。
//
// 描述表只放「下载什么、装到哪、装好长什么样」，下载与安装逻辑在
// [RuntimeInstaller] 里，二者分开是为了让组件可以纯数据地增删。

/// 单个产物的形态。
enum RuntimeArtifactKind {
  /// zip（含 wheel，wheel 本身也是 zip）。
  zip,

  /// 单个文件（如 CA 证书），按 [RuntimeArtifact.fileName] 落盘。
  file,
}

/// 组件由若干产物拼成。
///
/// JVM 只有一个 zip；PHP 是「zip + CA 证书」；Python 是「embeddable zip
/// + 十几个 wheel」。统一成产物列表后，安装器只需要一套下载-解压循环。
class RuntimeArtifact {
  const RuntimeArtifact({
    required this.label,
    required this.mirrors,
    this.kind = RuntimeArtifactKind.zip,
    this.target = '',
    this.dropPrefixes = const [],
    this.fileName,
  });

  /// 展示名（进度里显示「下载 Python（3/15）requests」）。
  final String label;

  /// 同一产物的等价地址；安装时实测速度择优。
  final List<String> mirrors;

  final RuntimeArtifactKind kind;

  /// 相对组件根目录的解压位置。空串表示根目录；wheel 用 `Lib/site-packages`。
  final String target;

  /// 解压后丢弃的路径前缀（PHP 的 `include/`、`lib/` 是开发头文件，占一半体积）。
  final List<String> dropPrefixes;

  /// [RuntimeArtifactKind.file] 的落地文件名。
  final String? fileName;
}

/// 组件描述。
class RuntimeComponent {
  const RuntimeComponent({
    required this.id,
    required this.name,
    required this.summary,
    required this.dirName,
    required this.version,
    required this.approxBytes,
    required this.probes,
    required this.artifacts,
    this.systemProperty,
    this.postStep = RuntimePostStep.none,
  });

  /// 稳定标识，用于进度单飞、日志与 UI key，不随展示名变化。
  final String id;

  /// 展示名（「JVM 运行时」）。
  final String name;

  /// 一行说明：讲清「什么时候需要」，用户据此决定要不要下。
  final String summary;

  /// 安装目录名。JRE 必须是 `jre`、Python 是 `python`、Node 是 `node`、
  /// PHP 是 `php`——`CompanionProcessManager` 靠这些名字拼 `-Dyingshi.*`。
  final String dirName;

  /// 版本号，写进安装目录的 `.version`，也用于展示「已安装 21.0.13.1」。
  final String version;

  /// 大致体积，仅用于文案；真实体积以响应头为准。
  final int approxBytes;

  /// 判定「装好了」的相对路径。必须挑真正决定可用性的文件：只查目录存在会让
  /// 半截解压看起来像成功，所以 Python 这里探到 `requests/__init__.py` 这一层。
  final List<String> probes;

  /// 产物清单，按顺序安装。
  final List<RuntimeArtifact> artifacts;

  /// 启动 companion 时要注入的 `-D<name>` 系统属性名。
  /// Java 侧三个运行时都支持显式覆盖（`PyRuntime` / `CatNodeRuntime` / `PhpRuntime`）。
  final String? systemProperty;

  /// 安装后处理步骤（改写 `._pth`、补 VC 运行库等）。
  final RuntimePostStep postStep;

  /// 组件要求的最低主版本号（`21.0.13.1` → `21`）。
  /// 用于判断本机已有的 JVM 是否够用，避免「装了个 17 也算可用」。
  int get majorVersion {
    final head = version.split('.').first;
    return int.tryParse(head) ?? 0;
  }

  /// 「约 46 MB」这类文案；不足 1 MB 时保留 KB，避免显示「约 0 MB」。
  String get sizeLabel {
    if (approxBytes >= 1024 * 1024) {
      return '约 ${(approxBytes / (1024 * 1024)).round()} MB';
    }
    return '约 ${(approxBytes / 1024).round()} KB';
  }
}

/// 安装后处理。用枚举而不是回调，是为了让组件表保持 `const`。
enum RuntimePostStep {
  none,

  /// embeddable CPython 默认不加载 site-packages，需要改写 `python3xx._pth`。
  pythonSitePackages,

  /// PHP 8.3 依赖 VC++ 2015-2022 运行库，优先从应用目录借 dll。
  phpVcRuntime,
}

/// JVM 运行时：Temurin JRE 21（x64, Windows）。
///
/// 为什么是 21 而不是 MisaTV 用的 17：本项目的 `companion-service.jar` 由构建机
/// JDK 21 编译，class 文件主版本 65，JRE 17 启动即 `UnsupportedClassVersionError`。
/// `CompanionProcessManager.minimumJavaMajorVersion` 也是 21，两边必须一致。
const RuntimeComponent jvmRuntimeComponent = RuntimeComponent(
  id: 'jvm',
  name: 'JVM 运行时',
  summary: '加载 .jar / .dex 蜘蛛源时按需下载',
  dirName: 'jre',
  version: '21.0.13.1',
  approxBytes: 46 * 1024 * 1024,
  probes: ['bin/java.exe', 'bin/server/jvm.dll'],
  artifacts: [
    RuntimeArtifact(
      label: 'Temurin JRE 21',
      mirrors: [
        'https://mirrors.tuna.tsinghua.edu.cn/Adoptium/21/jre/x64/windows/'
            'OpenJDK21U-jre_x64_windows_hotspot_21.0.13.1_2.zip',
        'https://ghfast.top/https://github.com/adoptium/temurin21-binaries/releases/download/'
            'jdk-21.0.13.1%2B2/OpenJDK21U-jre_x64_windows_hotspot_21.0.13.1_2.zip',
        'https://gh-proxy.com/https://github.com/adoptium/temurin21-binaries/releases/download/'
            'jdk-21.0.13.1%2B2/OpenJDK21U-jre_x64_windows_hotspot_21.0.13.1_2.zip',
        'https://github.com/adoptium/temurin21-binaries/releases/download/'
            'jdk-21.0.13.1%2B2/OpenJDK21U-jre_x64_windows_hotspot_21.0.13.1_2.zip',
      ],
    ),
  ],
);

/// Node 运行时：猫源（JS）靠它执行。
///
/// nodejs.org 的 dist 目录永久保留历史版本，可以写死版本号；npmmirror 是国内
/// 镜像，优先测速。官方 zip 解压后是 `node-v22.22.2-win-x64/node.exe`，
/// 安装器会自动下钻找到真正含 `node.exe` 的那层。
const RuntimeComponent nodeRuntimeComponent = RuntimeComponent(
  id: 'node',
  name: 'Node 运行时',
  summary: '加载猫源 JS 脚本时按需下载',
  dirName: 'node',
  version: '22.22.2',
  approxBytes: 33 * 1024 * 1024,
  probes: ['node.exe'],
  systemProperty: 'yingshi.node',
  artifacts: [
    RuntimeArtifact(
      label: 'Node',
      mirrors: [
        'https://npmmirror.com/mirrors/node/v22.22.2/node-v22.22.2-win-x64.zip',
        'https://nodejs.org/dist/v22.22.2/node-v22.22.2-win-x64.zip',
      ],
    ),
  ],
);

/// 便携 CPython：`.py` 源由 `PyRuntime` 以子进程方式拉起。
///
/// 为什么是 3.13 不是原项目声明的 3.14：3.14 的 ABI tag 是 cp314，而
/// `pycryptodome` 至今没有发布普通 cp314 wheel（只发了 free-threaded 的
/// cp313t），装上去会在 import 时崩。3.13 的 wheel 覆盖完整，pyshell 本身
/// 只用标准库，不受影响。
///
/// wheel 地址写死而**不在安装时查索引**：pypi.org 的 JSON 每个几 MB，国内直连
/// 20 秒拉不完；清华镜像的 HTML 索引还要额外解析。wheel 文件名带版本、内容
/// 不可变，写死更稳。升级时重跑 `tools/collect_python_wheels.py`。
const RuntimeComponent pythonRuntimeComponent = RuntimeComponent(
  id: 'python',
  name: 'Python 运行时',
  summary: '加载 .py 源脚本时按需下载（含常用第三方库）',
  dirName: 'python',
  version: '3.13.9',
  approxBytes: 36 * 1024 * 1024,
  probes: [
    'python.exe',
    'python313.zip',
    'Lib/site-packages/requests/__init__.py',
  ],
  systemProperty: 'yingshi.python',
  postStep: RuntimePostStep.pythonSitePackages,
  artifacts: [
    RuntimeArtifact(
      label: 'CPython',
      mirrors: [
        'https://mirrors.huaweicloud.com/python/3.13.9/python-3.13.9-embed-amd64.zip',
        'https://www.python.org/ftp/python/3.13.9/python-3.13.9-embed-amd64.zip',
      ],
    ),
    RuntimeArtifact(
      label: 'requests',
      target: 'Lib/site-packages',
      mirrors: [
        'https://pypi.tuna.tsinghua.edu.cn/packages/a0/f4/c67b0b3f1b9245e8d266f0f112c500d50e5b4e83cb6f3b71b6528104182a/requests-2.34.2-py3-none-any.whl',
      ],
    ),
    RuntimeArtifact(
      label: 'urllib3',
      target: 'Lib/site-packages',
      mirrors: [
        'https://pypi.tuna.tsinghua.edu.cn/packages/92/9d/c4e665119135114480843e7ab388fa94d8480650450e6f8e26b70d323a4c/urllib3-2.8.0-py3-none-any.whl',
      ],
    ),
    RuntimeArtifact(
      label: 'idna',
      target: 'Lib/site-packages',
      mirrors: [
        'https://pypi.tuna.tsinghua.edu.cn/packages/58/a2/bb081bab032533a855d44de1d56f8e8426114ff1ba5d1f07a438a0a654f8/idna-3.20-py3-none-any.whl',
      ],
    ),
    RuntimeArtifact(
      label: 'charset-normalizer',
      target: 'Lib/site-packages',
      mirrors: [
        'https://pypi.tuna.tsinghua.edu.cn/packages/6c/53/c56cbbee8fc51fef0a8e775488c4ef5205047a190ad850c43ad4b2ae7b35/charset_normalizer-3.5.3-cp313-cp313-win_amd64.whl',
      ],
    ),
    RuntimeArtifact(
      label: 'certifi',
      target: 'Lib/site-packages',
      mirrors: [
        'https://pypi.tuna.tsinghua.edu.cn/packages/6d/39/5eec3296860b94ac20bb8ed807725b88f6adfab3f343df592afd975f5f86/certifi-2026.11.20-py3-none-any.whl',
      ],
    ),
    RuntimeArtifact(
      label: 'beautifulsoup4',
      target: 'Lib/site-packages',
      mirrors: [
        'https://pypi.tuna.tsinghua.edu.cn/packages/88/c6/92fcd42f1ba33e1184263f25bfabf3d27c383410470f169e4b8163bf9c17/beautifulsoup4-4.15.0-py3-none-any.whl',
      ],
    ),
    RuntimeArtifact(
      label: 'soupsieve',
      target: 'Lib/site-packages',
      mirrors: [
        'https://pypi.tuna.tsinghua.edu.cn/packages/88/73/6a2087c72975cfc07394623bca8d17654342ea4055ae368deafe5a81a542/soupsieve-4.1-py3-none-any.whl',
      ],
    ),
    RuntimeArtifact(
      label: 'typing-extensions',
      target: 'Lib/site-packages',
      mirrors: [
        'https://pypi.tuna.tsinghua.edu.cn/packages/49/d3/b8441a820a491ddfc024b0b0cf0393375b75ea13866d9c66727e54c2fc80/typing_extensions-4.16.0-py3-none-any.whl',
      ],
    ),
    RuntimeArtifact(
      label: 'pyquery',
      target: 'Lib/site-packages',
      mirrors: [
        'https://pypi.tuna.tsinghua.edu.cn/packages/2f/d2/5eab7f15bdb63c5281f625a003e999ef3f843c35972c936b07ea868cb854/pyquery-2.1.0-py3-none-any.whl',
      ],
    ),
    RuntimeArtifact(
      label: 'cssselect',
      target: 'Lib/site-packages',
      mirrors: [
        'https://pypi.tuna.tsinghua.edu.cn/packages/08/ae/f24b3aac56ba91a29c9d3a31c07a9ad4e9eb500e5d212742bb6d348edaef/cssselect-1.6.0-py3-none-any.whl',
      ],
    ),
    RuntimeArtifact(
      label: 'lxml',
      target: 'Lib/site-packages',
      mirrors: [
        'https://pypi.tuna.tsinghua.edu.cn/packages/c0/28/e46a7702bd95e9043291f7c3539b6184cba66f96cea9936f20939b284eeb/lxml-6.1.3-cp313-cp313-win_amd64.whl',
      ],
    ),
    RuntimeArtifact(
      label: 'pycryptodome',
      target: 'Lib/site-packages',
      mirrors: [
        'https://pypi.tuna.tsinghua.edu.cn/packages/f3/10/f375e028f5e3b10b4858010ffa391e66c7b61a410284bdc3e0f351edefc7/pycryptodome-4.6.0-cp39-abi3-win_amd64.whl',
      ],
    ),
    RuntimeArtifact(
      label: 'numpy',
      target: 'Lib/site-packages',
      mirrors: [
        'https://pypi.tuna.tsinghua.edu.cn/packages/45/74/bb9161943fb65caf24e4bb04c788f5c7815e6cb78ac595e7f46781033c82/numpy-2.5.5-cp313-cp313-win_amd64.whl',
      ],
    ),
    RuntimeArtifact(
      label: 'pywasm',
      target: 'Lib/site-packages',
      mirrors: [
        'https://pypi.tuna.tsinghua.edu.cn/packages/73/63/7a6587416281ddcd987b2a19e79406c9ba13b63fd5c7ae34ae35a06f89b1/pywasm-2.2.3-py2.py3-none-any.whl',
      ],
    ),
  ],
);

/// PHP 运行时：道长 T3（type=3）源需要独立解释器。
///
/// 注意 windows.php.net 只保留每个分支的**最新小版本**（8.3.36 已经 404），
/// 升级时同时改 `version` 与 zip 地址。
const RuntimeComponent phpRuntimeComponent = RuntimeComponent(
  id: 'php',
  name: 'PHP 运行时',
  summary: '加载 T3（PHP）源时按需下载',
  dirName: 'php',
  version: '8.3.37',
  approxBytes: 33 * 1024 * 1024,
  probes: ['php.exe', 'ext/php_curl.dll'],
  systemProperty: 'yingshi.php',
  postStep: RuntimePostStep.phpVcRuntime,
  artifacts: [
    RuntimeArtifact(
      label: 'PHP',
      // 开发头文件与调试器占一半体积，运行时不需要。
      dropPrefixes: ['include/', 'lib/', 'extras/', 'phpdbg.exe', 'php-cgi.exe'],
      mirrors: [
        'https://downloads.php.net/~windows/releases/php-8.3.37-nts-Win32-vs16-x64.zip',
        'https://windows.php.net/downloads/releases/php-8.3.37-nts-Win32-vs16-x64.zip',
      ],
    ),
    RuntimeArtifact(
      label: 'CA 证书',
      kind: RuntimeArtifactKind.file,
      fileName: 'cacert.pem',
      mirrors: ['https://curl.se/ca/cacert.pem'],
    ),
  ],
);

/// 设置页按这个顺序渲染。
const List<RuntimeComponent> runtimeComponents = [
  jvmRuntimeComponent,
  nodeRuntimeComponent,
  pythonRuntimeComponent,
  phpRuntimeComponent,
];
