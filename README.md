# 知课

知课是一款面向大学生的 OpenHarmony 课表查看工具，核心能力是从正方教务系统页面解析课程数据，并自动导入本地周课表。

## 一句话简介

智能导入课表，轻松安排上课时间。

## 功能特性

- 周课表视图：主界面展示周一至周日，支持第 1-20 周切换。
- 11 节课程时间：默认覆盖早、午、晚 11 节课，并可在“我的”页面调整每节课时间。
- 教务系统导入：内置 WebView，可使用 PC User-Agent 打开教务系统并解析课表。
- 正方课表适配：针对正方教务常见列表课表和网格课表结构做了解析适配。
- 本地持久化：导入成功后写入应用文件目录，关闭后台后再次打开仍可恢复课表。
- 课程详情：点击课程卡片可查看课程名、周几、节次、时间、地点、教师等信息。
- 柔和配色：同一门课程使用固定的低饱和色块，方便快速识别。

## 项目结构

```text
MyTimeTable
├── AppScope/                         # 应用级配置、名称、图标资源
├── entry/
│   ├── src/main/ets/pages/Index.ets   # 首页、课表、我的、欢迎页、本地课表读取
│   ├── src/main/ets/pages/WebImport.ets # 教务网页打开、课表解析、导入保存
│   ├── src/main/ets/entryability/     # 应用入口 Ability
│   └── src/main/resources/            # 页面、颜色、字符串、媒体资源
├── build-profile.json5                # 工程构建和签名配置
├── entry/build-profile.json5          # entry 模块构建配置
├── oh-package.json5                   # 工程依赖配置
└── README.md
```

## 开发环境

- DevEco Studio
- HarmonyOS / OpenHarmony SDK 6.1.1
- ArkTS Stage 模型
- 目标设备：鸿蒙设备终端

## 运行方式

1. 使用 DevEco Studio 打开项目根目录。
2. 等待依赖同步完成。
3. 选择模拟器或真机。
4. 点击 Run 运行应用。

## 发布构建

项目当前构建模式保留为 `release`。为了避免把个人证书信息提交到 GitHub，`build-profile.json5` 中的签名材料已改为占位符。

发布前请在 DevEco Studio 中重新配置签名证书，或将以下字段替换为你自己的本地证书信息：

```json5
"storeFile": "YOUR_RELEASE_CERTIFICATE.p12",
"storePassword": "YOUR_STORE_PASSWORD",
"keyAlias": "YOUR_KEY_ALIAS",
"keyPassword": "YOUR_KEY_PASSWORD",
"profile": "YOUR_RELEASE_PROFILE.p7b",
"certpath": "YOUR_RELEASE_CERTIFICATE.cer"
```

## 使用说明

1. 首次进入应用会显示欢迎页，随后进入空课表。
2. 在底部导航进入“我的”。
3. 输入教务系统地址，点击“打开”。
4. 登录教务系统并进入个人课表页面。
5. 点击底部“解析课表”，解析成功后会自动导入首页课表。
6. 回到首页后可切换周数，点击课程卡片查看详情。

## 课表解析代码说明

课表解析主要集中在 [WebImport.ets](entry/src/main/ets/pages/WebImport.ets)，首页展示和本地读取主要集中在 [Index.ets](entry/src/main/ets/pages/Index.ets)。

### 数据流

```text
教务网页
  ↓ WebView 打开 PC 版页面
runJavaScript 注入解析脚本
  ↓
扫描正方课表表格与页面文本
  ↓
生成 ImportedCourse[]
  ↓
去重、清洗课程名和详情
  ↓
写入 AppStorage + courses.json
  ↓
Index.ets 读取并渲染周课表
```

### 课程数据结构

解析后的课程会统一整理为 `ImportedCourse`：

```ts
interface ImportedCourse {
  day: number;          // 0-6，分别表示周一到周日
  startSection: number; // 开始节次，范围 1-11
  endSection: number;   // 结束节次，范围 1-11
  name: string;         // 课程名
  detail: string;       // 周次、地点、教师、课程类型等信息
}
```

首页只依赖这个结构渲染课表，因此解析层和展示层之间保持了比较清晰的边界。

### 正方课表解析策略

当前解析逻辑主要面向正方教务系统，按优先级依次处理：

- 优先读取 `#kblist_table` 这类列表课表结构。
- 兼容 `#kbgrid_table_0` 这类网格课表结构。
- 当表格结构不稳定时，从整段网页文本中按“节次 + 课程名 + 周数”兜底恢复课程。
- 支持同一节次多门课程，例如同一时间段不同周次课程。
- 支持同一门课在不同周几、不同节次重复出现。
- 支持 1-2、3-4、9-11 这类连堂课程，并在首页合并为一张连续课程卡。
- 支持 1-16周、2-6周,9-16周、单/双周等周次筛选。

### 关键方法

- `parseListSchedule()`：主解析入口，向 WebView 注入脚本并接收解析结果。
- `flattenImportedText()`：统一处理换行、空格和不可见字符，提升正则匹配稳定性。
- `normalizeImportedCourse()`：清理课程名，去掉周几、节次、星标和教学班等冗余信息。
- `normalizeImportedDetail()`：清理详情字段，避免教学班编号等长文本进入课程卡片。
- `dedupeImportedCourses()`：去掉完全重复课程，同时保留同一课程在不同时间段的记录。
- `recoverCoursesFromText()`：表格解析失败时的文本兜底恢复逻辑。
- `diagnoseSchedulePage()`：生成解析预览，用于查看页面表格、课程块和匹配结果。

### 本地导入与持久化

解析成功后，`WebImport.ets` 会调用 `saveImportedCourses()`：

- 写入 `AppStorage`，让首页返回后立即刷新。
- 写入应用文件目录下的 `courses.json`，让应用杀后台后再次打开仍能恢复课表。

首页 `Index.ets` 中的 `syncImportedCourses()` 会同时检查 `AppStorage` 和本地文件；`loadCoursesFromFile()` 负责从 `courses.json` 读回数据。

### 首页渲染逻辑

`Index.ets` 只关心标准化后的 `ImportedCourse[]`：

- `isCourseInCurrentWeek()` 根据当前周筛选课程。
- `getCourseSpan()` 计算连堂课程跨度。
- `getCourseBackgroundColor()` 等方法保证同一门课程使用固定颜色。
- `showCourseDetail()` 用于点击课程卡片后展示完整信息。

不同学校的正方页面可能存在字段和结构差异。如果解析异常，可在导入页面点击“解析预览”，复制页面结构信息后再调整解析规则。

## 隐私说明

知课只在本地保存已解析的课表数据，不主动上传课程信息。内置网页仅用于用户手动访问教务系统并解析当前页面内容。

## 应用信息

- 应用名称：知课
- Slogan：方寸之间，安排妥当。
- 简介：智能导入课表，轻松安排上课时间。
