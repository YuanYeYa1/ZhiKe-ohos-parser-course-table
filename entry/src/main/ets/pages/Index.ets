import router from '@ohos.router';
import promptAction from '@ohos.promptAction';
import { common } from '@kit.AbilityKit';
import fs from '@ohos.file.fs';

interface ImportedCourse {
  // day: 0 表示周一，6 表示周日；节次范围为 1-11。
  day: number;
  startSection: number;
  endSection: number;
  name: string;
  detail: string;
}

@Entry
@Component
struct Index {
  @State currentWeek: number = 1;
  @State activeTab: number = 0;
  @State importUrlInput: string = '';
  @State showWelcome: boolean = true;
  @StorageLink('importedCoursesJson') importedCoursesJson: string = '[]';
  @State classTimes: string[] = [
    '08:00-08:45',
    '08:55-09:40',
    '10:10-10:55',
    '11:05-11:50',
    '14:00-14:45',
    '14:55-15:40',
    '16:10-16:55',
    '17:05-17:50',
    '19:00-19:45',
    '19:55-20:40',
    '20:50-21:35'
  ];

  private readonly days: string[] = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
  private readonly sections: number[] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11];
  private readonly courseFileName: string = 'courses.json';
  private readonly courseBackgroundColors: string[] = [
    '#DCEFE7', '#E8E1F2', '#F7E3D5', '#DDEAF6', '#F4E7EC',
    '#E9E7D6', '#D7ECEB', '#F2E4CB', '#E1E8F5', '#EADFD8'
  ];
  private readonly courseBorderColors: string[] = [
    '#9BCDBB', '#BBA9D5', '#E2B99E', '#A8C7E4', '#D9AFC0',
    '#CEC99F', '#98CBC7', '#D9B878', '#AABADB', '#C8AEA1'
  ];
  private readonly courseTextColors: string[] = [
    '#2E6251', '#5A4872', '#7B4F35', '#365C78', '#75495B',
    '#66613C', '#2E6561', '#725A28', '#465878', '#6B5045'
  ];

  aboutToAppear(): void {
    this.syncImportedCourses();
    setTimeout(() => {
      this.showWelcome = false;
    }, 1500);
  }

  onPageShow(): void {
    this.syncImportedCourses();
  }

  private syncImportedCourses(): void {
    // 先读页面间共享状态，再读本地文件，保证导入页返回和冷启动都能恢复课表。
    const storedCourses = AppStorage.Get('importedCoursesJson') as string | undefined;
    if (storedCourses && storedCourses !== this.importedCoursesJson) {
      this.applyImportedCourses(storedCourses);
    }
    this.loadCoursesFromFile();
  }

  private applyImportedCourses(coursesJson: string): void {
    this.importedCoursesJson = coursesJson;
    AppStorage.SetOrCreate('importedCoursesJson', coursesJson);
    if (this.getImportedCourses().length > 0) {
      this.activeTab = 0;
    }
  }

  private getCourseFilePath(): string {
    const context = getContext(this) as common.UIAbilityContext;
    return `${context.filesDir}/${this.courseFileName}`;
  }

  private decodeUtf8(bytes: Uint8Array): string {
    // ArkTS 当前文件 API 读出的是字节，这里手动按 UTF-8 还原，避免中文课程信息乱码。
    let result: string = '';
    let index: number = 0;

    while (index < bytes.length) {
      const first: number = bytes[index];
      if (first < 0x80) {
        result += String.fromCharCode(first);
        index += 1;
      } else if (first < 0xE0 && index + 1 < bytes.length) {
        const code: number = ((first & 0x1F) << 6) | (bytes[index + 1] & 0x3F);
        result += String.fromCharCode(code);
        index += 2;
      } else if (first < 0xF0 && index + 2 < bytes.length) {
        const code: number = ((first & 0x0F) << 12) |
          ((bytes[index + 1] & 0x3F) << 6) |
          (bytes[index + 2] & 0x3F);
        result += String.fromCharCode(code);
        index += 3;
      } else if (index + 3 < bytes.length) {
        const codePoint: number = ((first & 0x07) << 18) |
          ((bytes[index + 1] & 0x3F) << 12) |
          ((bytes[index + 2] & 0x3F) << 6) |
          (bytes[index + 3] & 0x3F);
        const offset: number = codePoint - 0x10000;
        result += String.fromCharCode(0xD800 + (offset >> 10), 0xDC00 + (offset & 0x3FF));
        index += 4;
      } else {
        index += 1;
      }
    }

    return result;
  }

  private loadCoursesFromFile(): void {
    try {
      const filePath = this.getCourseFilePath();
      const stat = fs.statSync(filePath);
      const file = fs.openSync(filePath, fs.OpenMode.READ_ONLY);
      const buffer = new ArrayBuffer(stat.size);
      fs.readSync(file.fd, buffer);
      fs.closeSync(file);
      const coursesJson = this.decodeUtf8(new Uint8Array(buffer));
      if (coursesJson.length > 2 && coursesJson !== this.importedCoursesJson) {
        this.applyImportedCourses(coursesJson);
      }
    } catch (error) {
      // 首次启动没有本地课表文件是正常情况，保持空课表即可。
    }
  }

  private normalizeUrl(url: string): string {
    const trimmedUrl = url.trim();

    if (trimmedUrl.length === 0) {
      return 'about:blank';
    }

    if (trimmedUrl.startsWith('http://') || trimmedUrl.startsWith('https://')) {
      return trimmedUrl;
    }

    return `https://${trimmedUrl}`;
  }

  private getClassStartTime(index: number): string {
    const timeParts: string[] = this.classTimes[index].split('-');
    return timeParts[0] ? timeParts[0] : '';
  }

  private getClassEndTime(index: number): string {
    const timeParts: string[] = this.classTimes[index].split('-');
    return timeParts[1] ? timeParts[1] : '';
  }

  private getImportedCourses(): ImportedCourse[] {
    try {
      return JSON.parse(this.importedCoursesJson) as ImportedCourse[];
    } catch (error) {
      return [];
    }
  }

  private isCourseInCurrentWeek(course: ImportedCourse): boolean {
    // detail 的第一段保存周次信息，如 1-16周、2-6周,9-16周、2-16周(双)。
    const weekText: string = course.detail.split('|')[0] ? course.detail.split('|')[0].trim() : '';
    const weekRegExp: RegExp = /(\d{1,2})(?:\s*[-至~－—]\s*(\d{1,2}))?\s*(单|双)?周/g;
    let matched: boolean = false;
    let match = weekRegExp.exec(weekText);

    while (match !== null) {
      matched = true;
      const startWeek: number = Number(match[1]);
      const endWeek: number = match[2] ? Number(match[2]) : startWeek;
      const parity: string = match[3] ? match[3] : '';

      if (this.currentWeek >= startWeek && this.currentWeek <= endWeek) {
        if (parity === '单' && this.currentWeek % 2 === 0) {
          match = weekRegExp.exec(weekText);
          continue;
        }
        if (parity === '双' && this.currentWeek % 2 !== 0) {
          match = weekRegExp.exec(weekText);
          continue;
        }
        return true;
      }

      match = weekRegExp.exec(weekText);
    }

    return !matched;
  }

  private getCourse(day: number, section: number): ImportedCourse | undefined {
    const courses: ImportedCourse[] = this.getCourses(day, section);
    return courses.length > 0 ? courses[0] : undefined;
  }

  private getCourses(day: number, section: number): ImportedCourse[] {
    const courses: ImportedCourse[] = this.getImportedCourses();

    return courses.filter((course: ImportedCourse) => {
      return course.day === day && course.startSection <= section && course.endSection >= section && this.isCourseInCurrentWeek(course);
    });
  }

  private getStartingCourses(day: number, section: number): ImportedCourse[] {
    const courses: ImportedCourse[] = this.getImportedCourses();

    return courses.filter((course: ImportedCourse) => {
      return course.day === day && course.startSection === section && this.isCourseInCurrentWeek(course);
    });
  }

  private isCourseStart(day: number, section: number): boolean {
    return this.getStartingCourses(day, section).length > 0;
  }

  private isCourseDisplaySection(course: ImportedCourse, section: number): boolean {
    const displaySection: number = Math.ceil((course.startSection + course.endSection) / 2);
    return displaySection === section;
  }

  private getDisplayCourses(day: number, section: number): ImportedCourse[] {
    const courses: ImportedCourse[] = this.getCourses(day, section);

    return courses.filter((course: ImportedCourse) => {
      return this.isCourseDisplaySection(course, section);
    });
  }

  private hasDisplayCourse(day: number, section: number): boolean {
    return this.getDisplayCourses(day, section).length > 0;
  }

  private isCourseEnd(day: number, section: number): boolean {
    const courses: ImportedCourse[] = this.getCourses(day, section);
    return courses.length > 0 && courses.some((course: ImportedCourse) => {
      return course.endSection === section;
    });
  }

  private hasCourse(day: number, section: number): boolean {
    return this.getCourses(day, section).length > 0;
  }

  private getCourseName(day: number, section: number): string {
    const courses: ImportedCourse[] = this.getStartingCourses(day, section);
    return courses.map((course: ImportedCourse) => {
      return course.name;
    }).join('\n');
  }

  private getCourseDetail(day: number, section: number): string {
    const courses: ImportedCourse[] = this.getStartingCourses(day, section);
    return courses.map((course: ImportedCourse) => {
      return this.getVisibleCourseDetail(course.detail);
    }).filter((detail: string) => {
      return detail.length > 0;
    }).join('\n');
  }

  private getVisibleCourseDetail(detail: string): string {
    // 课表卡片只保留地点、教师、课程类型等关键信息，隐藏校区和教学班编号。
    return detail
      .split('|')
      .map((part: string) => {
        return part
          .replace(/[\u4e00-\u9fa5]{2,12}校区/g, '')
          .replace(/教学班.*$/, '')
          .replace(/教学班组成.*$/, '')
          .replace(/\(\d{4}\s*[-－]\s*\d{4}\s*[-－]\s*\d\).*$/, '')
          .replace(/\s+/g, ' ')
          .trim();
      })
      .filter((part: string) => {
        return part.length > 0;
      })
      .join(' | ');
  }

  private getCourseColorIndex(courseName: string): number {
    // 同一门课通过课程名散列到固定色板，保证不同周次/节次颜色一致。
    let hash: number = 0;
    for (let index = 0; index < courseName.length; index++) {
      hash = (hash * 31 + courseName.charCodeAt(index)) % this.courseBackgroundColors.length;
    }
    return Math.abs(hash) % this.courseBackgroundColors.length;
  }

  private getColorCourse(day: number, section: number): ImportedCourse | undefined {
    const courses: ImportedCourse[] = this.getStartingCourses(day, section);
    return courses.length > 0 ? courses[0] : undefined;
  }

  private getCourseBackgroundColor(day: number, section: number): string {
    const course = this.getColorCourse(day, section);
    if (!course) {
      return '#DBEAFE';
    }
    const color = this.courseBackgroundColors[this.getCourseColorIndex(course.name)];
    return color ? color : '#DBEAFE';
  }

  private getCourseBorderColor(day: number, section: number): string {
    const course = this.getColorCourse(day, section);
    if (!course) {
      return '#60A5FA';
    }
    const color = this.courseBorderColors[this.getCourseColorIndex(course.name)];
    return color ? color : '#60A5FA';
  }

  private getCourseTextColor(day: number, section: number): string {
    const course = this.getColorCourse(day, section);
    if (!course) {
      return '#1E40AF';
    }
    const color = this.courseTextColors[this.getCourseColorIndex(course.name)];
    return color ? color : '#1E40AF';
  }

  private getCourseSpan(day: number, section: number): number {
    // 连堂课使用同一张课程卡覆盖多节课，而不是在每个格子重复绘制。
    const courses: ImportedCourse[] = this.getStartingCourses(day, section);
    let endSection: number = section;

    courses.forEach((course: ImportedCourse) => {
      if (course.endSection > endSection) {
        endSection = course.endSection;
      }
    });

    return endSection - section + 1;
  }

  private getCourseCardX(day: number): number {
    return 36 + day * 39 + 1;
  }

  private getCourseCardY(section: number): number {
    return 42 + (section - 1) * 68 + 2;
  }

  private getCourseCardHeight(day: number, section: number): number {
    return this.getCourseSpan(day, section) * 68 - 4;
  }

  private showCourseDetail(day: number, section: number): void {
    // 点击任意被课程覆盖的格子时，弹窗展示该时段的完整课程信息。
    const courses: ImportedCourse[] = this.getCourses(day, section);

    if (courses.length === 0) {
      return;
    }

    const message = courses.map((course: ImportedCourse) => {
      const startTime = this.classTimes[course.startSection - 1] ? this.classTimes[course.startSection - 1] : '';
      const endTime = this.classTimes[course.endSection - 1] ? this.classTimes[course.endSection - 1] : startTime;
      return [
        `${course.name}`,
        `${this.days[course.day]} 第 ${course.startSection}-${course.endSection} 节`,
        `时间：${startTime}${endTime !== startTime ? ` 至 ${endTime}` : ''}`,
        course.detail.length > 0 ? `详情：${this.getVisibleCourseDetail(course.detail)}` : '暂无更多详情'
      ].join('\n');
    }).join('\n\n');

    promptAction.showDialog({
      title: courses.length > 1 ? '课程详情' : courses[0].name,
      message: message,
      buttons: [
        {
          text: '知道了',
          color: '#2563EB'
        }
      ]
    });
  }

  @Builder
  SchedulePage() {
    Column({ space: 14 }) {
      Row() {
        Column() {
          Text('知课')
            .fontSize(28)
            .fontWeight(FontWeight.Bold)
            .fontColor('#0F172A')

          Text('周一至周日')
            .fontSize(14)
            .fontColor('#64748B')
            .margin({ top: 4 })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Row({ space: 8 }) {
          Button('<')
            .width(38)
            .height(34)
            .fontSize(16)
            .fontColor('#2563EB')
            .backgroundColor('#DBEAFE')
            .borderRadius(17)
            .onClick(() => {
              if (this.currentWeek > 1) {
                this.currentWeek -= 1;
              }
            })

          Text(`第 ${this.currentWeek} 周`)
            .height(34)
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .fontColor('#1E40AF')
            .textAlign(TextAlign.Center)
            .padding({ left: 12, right: 12 })
            .backgroundColor('#EFF6FF')
            .borderRadius(17)

          Button('>')
            .width(38)
            .height(34)
            .fontSize(16)
            .fontColor('#2563EB')
            .backgroundColor('#DBEAFE')
            .borderRadius(17)
            .onClick(() => {
              if (this.currentWeek < 20) {
                this.currentWeek += 1;
              }
            })
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Scroll() {
        Stack({ alignContent: Alignment.TopStart }) {
          Column() {
            Row() {
              Text('节次')
                .width(36)
                .height(42)
                .fontSize(11)
                .fontWeight(FontWeight.Bold)
                .fontColor('#64748B')
                .textAlign(TextAlign.Center)

              ForEach(this.days, (dayName: string) => {
                Text(dayName)
                  .width(39)
                  .height(42)
                  .fontSize(11)
                  .fontWeight(FontWeight.Bold)
                  .fontColor('#334155')
                  .textAlign(TextAlign.Center)
              })
            }
            .width(309)

            ForEach(this.sections, (section: number) => {
              Row() {
                Column() {
                  Text(`${section}`)
                    .fontSize(13)
                    .fontWeight(FontWeight.Bold)
                    .fontColor('#334155')

                  Text(this.getClassStartTime(section - 1))
                    .fontSize(8)
                    .fontColor('#94A3B8')
                    .margin({ top: 3 })

                  Text(this.getClassEndTime(section - 1))
                    .fontSize(8)
                    .fontColor('#94A3B8')
                    .margin({ top: 1 })
                }
                .width(36)
                .height(68)
                .justifyContent(FlexAlign.Center)

                ForEach(this.days, (dayName: string, dayIndex: number) => {
                  Column()
                    .width(37)
                    .height(64)
                    .margin({ left: 1, right: 1, top: 2, bottom: 2 })
                    .backgroundColor('#F8FAFC')
                    .borderRadius(10)
                    .border({
                      width: 1,
                      color: '#E2E8F0'
                    })
                    .onClick(() => {
                      this.showCourseDetail(dayIndex, section);
                    })
                })
              }
              .width(309)
              .height(68)
            })
          }
          .width(309)
          .height(790)

          ForEach(this.days, (dayName: string, dayIndex: number) => {
            ForEach(this.sections, (section: number) => {
              if (this.isCourseStart(dayIndex, section)) {
                Column() {
                  Text(this.getCourseName(dayIndex, section))
                    .fontSize(8)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(this.getCourseTextColor(dayIndex, section))
                    .maxLines(4)
                    .textAlign(TextAlign.Center)

                  Text(this.getCourseDetail(dayIndex, section))
                    .fontSize(7)
                    .fontColor(this.getCourseTextColor(dayIndex, section))
                    .maxLines(4)
                    .textAlign(TextAlign.Center)
                    .margin({ top: 3 })
                }
                .width(37)
                .height(this.getCourseCardHeight(dayIndex, section))
                .justifyContent(FlexAlign.Center)
                .padding(3)
                .backgroundColor(this.getCourseBackgroundColor(dayIndex, section))
                .borderRadius(10)
                .border({
                  width: 1,
                  color: this.getCourseBorderColor(dayIndex, section)
                })
                .position({
                  x: this.getCourseCardX(dayIndex),
                  y: this.getCourseCardY(section)
                })
                .onClick(() => {
                  this.showCourseDetail(dayIndex, section);
                })
              }
            })
          })
        }
        .width(309)
        .height(790)
      }
      .scrollable(ScrollDirection.Horizontal)
      .width('100%')
      .padding({ left: 8, right: 8, bottom: 8 })
      .backgroundColor('#FFFFFF')
      .borderRadius(18)

      Column() {
        Text(this.getImportedCourses().length > 0 ? `已导入 ${this.getImportedCourses().length} 门课程` : '当前周暂无课程')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor('#334155')

        Text(this.getImportedCourses().length > 0 ? '课程已自动写入课表，可继续导入覆盖更新' : '可在“我的”中打开正方教务并导入课表')
          .fontSize(13)
          .fontColor('#94A3B8')
          .textAlign(TextAlign.Center)
          .margin({ top: 8 })
      }
      .width('100%')
      .padding(18)
      .backgroundColor('#FFFFFF')
      .borderRadius(18)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 24, bottom: 12 })
  }

  @Builder
  MinePage() {
    Column({ space: 16 }) {
      Text('我的')
        .fontSize(28)
        .fontWeight(FontWeight.Bold)
        .fontColor('#0F172A')
        .width('100%')

      Column({ space: 10 }) {
        Text('本地课表')
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor('#111827')
          .width('100%')

        Text('可通过正方教务导入课程，也可以调整上课时间')
          .fontSize(14)
          .fontColor('#64748B')
          .width('100%')
      }
      .width('100%')
      .padding(20)
      .backgroundColor('#FFFFFF')
      .borderRadius(18)

      Column({ space: 12 }) {
        Text('上课时间')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor('#111827')
          .width('100%')

        Text('可按学校作息调整，每节课格式如 08:00-08:45')
          .fontSize(13)
          .fontColor('#94A3B8')
          .width('100%')

        ForEach(this.sections, (section: number) => {
          Row({ space: 10 }) {
            Text(`第 ${section} 节`)
              .width(58)
              .fontSize(13)
              .fontColor('#475569')

            TextInput({ text: this.classTimes[section - 1], placeholder: '开始-结束' })
              .height(40)
              .layoutWeight(1)
              .fontSize(14)
              .backgroundColor('#F8FAFC')
              .borderRadius(10)
              .padding({ left: 12, right: 12 })
              .onChange((value: string) => {
                const nextTimes: string[] = this.classTimes.slice();
                nextTimes[section - 1] = value;
                this.classTimes = nextTimes;
              })
          }
          .width('100%')
        })
      }
      .width('100%')
      .padding(18)
      .backgroundColor('#FFFFFF')
      .borderRadius(18)

      Column({ space: 12 }) {
        Text('教务导入')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor('#111827')
          .width('100%')

        Row({ space: 8 }) {
          TextInput({ text: this.importUrlInput, placeholder: '输入教务网站地址' })
            .height(42)
            .layoutWeight(1)
            .fontSize(14)
            .backgroundColor('#F8FAFC')
            .borderRadius(12)
            .padding({ left: 12, right: 12 })
            .onChange((value: string) => {
              this.importUrlInput = value;
            })

          Button('打开')
            .width(72)
            .height(42)
            .fontSize(14)
            .fontColor('#FFFFFF')
            .backgroundColor('#2563EB')
            .borderRadius(12)
            .onClick(() => {
              router.pushUrl({
                url: 'pages/WebImport',
                params: {
                  targetUrl: this.normalizeUrl(this.importUrlInput)
                }
              });
            })
        }
        .width('100%')

        Text('将在独立页面以 PC 标识打开，底部提供课表解析入口')
          .fontSize(12)
          .fontColor('#94A3B8')
          .width('100%')
      }
      .width('100%')
      .padding(18)
      .backgroundColor('#FFFFFF')
      .borderRadius(18)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 24, bottom: 12 })
  }

  @Builder
  BottomNavigation() {
    Row() {
      Column({ space: 4 }) {
        Text('课表')
          .fontSize(16)
          .fontWeight(this.activeTab === 0 ? FontWeight.Bold : FontWeight.Regular)
          .fontColor(this.activeTab === 0 ? '#2563EB' : '#94A3B8')

        Column()
          .width(20)
          .height(3)
          .borderRadius(2)
          .backgroundColor(this.activeTab === 0 ? '#2563EB' : '#FFFFFF')
      }
      .layoutWeight(1)
      .height(58)
      .justifyContent(FlexAlign.Center)
      .onClick(() => {
        this.activeTab = 0;
      })

      Column({ space: 4 }) {
        Text('我的')
          .fontSize(16)
          .fontWeight(this.activeTab === 1 ? FontWeight.Bold : FontWeight.Regular)
          .fontColor(this.activeTab === 1 ? '#2563EB' : '#94A3B8')

        Column()
          .width(20)
          .height(3)
          .borderRadius(2)
          .backgroundColor(this.activeTab === 1 ? '#2563EB' : '#FFFFFF')
      }
      .layoutWeight(1)
      .height(58)
      .justifyContent(FlexAlign.Center)
      .onClick(() => {
        this.activeTab = 1;
      })
    }
    .width('100%')
    .height(66)
    .padding({ left: 24, right: 24 })
    .backgroundColor('#FFFFFF')
    .border({
      width: { top: 1 },
      color: '#E2E8F0'
    })
  }

  @Builder
  WelcomePage() {
    Column() {
      Blank()
        .layoutWeight(1)

      Column({ space: 18 }) {
        Image($r('app.media.gemini_svg'))
          .width(96)
          .height(96)
          .objectFit(ImageFit.Contain)

        Column({ space: 8 }) {
          Text('方寸之间，安排妥当。')
            .fontSize(24)
            .fontWeight(FontWeight.Bold)
            .fontColor('#1E293B')
            .textAlign(TextAlign.Center)

          Text('你的口袋时间管家，让每一次上课都从容不迫。')
            .fontSize(14)
            .fontColor('#64748B')
            .textAlign(TextAlign.Center)
            .lineHeight(22)
            .padding({ left: 34, right: 34 })
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Center)

      Blank()
        .layoutWeight(1)

      Text('知课')
        .fontSize(13)
        .fontColor('#94A3B8')
        .margin({ bottom: 32 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F8FAFC')
  }

  @Builder
  HomePage() {
    Column() {
      Scroll() {
        if (this.activeTab === 0) {
          this.SchedulePage();
        } else {
          this.MinePage();
        }
      }
      .layoutWeight(1)
      .width('100%')

      this.BottomNavigation();
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F8FAFC')
  }

  build() {
    Stack() {
      this.HomePage();

      if (this.showWelcome) {
        this.WelcomePage();
      }
    }
    .width('100%')
    .height('100%')
  }
}
