import router from '@ohos.router';
import web_webview from '@ohos.web.webview';
import { common } from '@kit.AbilityKit';
import fs from '@ohos.file.fs';

interface WebImportParams {
  targetUrl?: string;
}

interface ZhengfangParseResult {
  source?: string;
  tableCount: number;
  courseCellCount: number;
  titleNodeCount?: number;
  parseError?: string;
  samples?: string[];
  courses?: ImportedCourse[];
}

interface ImportedCourse {
  // 与首页保持一致：day 取 0-6，节次取 1-11。
  day: number;
  startSection: number;
  endSection: number;
  name: string;
  detail: string;
}

@Entry
@Component
struct WebImport {
  @State targetUrl: string = 'about:blank';
  @State urlInput: string = '';
  @State parseStatus: string = '进入教务系统并打开课表页面后，点击下方按钮解析。';
  @State parsePreview: string = '';

  private readonly pcUserAgent: string =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';
  private readonly courseFileName: string = 'courses.json';
  private webController: web_webview.WebviewController = new web_webview.WebviewController();

  aboutToAppear(): void {
    const params = router.getParams() as WebImportParams;
    const url = params.targetUrl ? params.targetUrl : 'about:blank';

    this.targetUrl = url;
    this.urlInput = url === 'about:blank' ? '' : url;
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

  private openUrl(): void {
    this.targetUrl = this.normalizeUrl(this.urlInput);
    try {
      this.webController.loadUrl(this.targetUrl);
    } catch (error) {
      this.parseStatus = '打开网页失败：请检查网址是否正确。';
      this.parsePreview = JSON.stringify(error);
    }
  }

  private saveImportedCourses(coursesJson: string, afterSave: () => void): void {
    // 同时写 AppStorage 和应用文件目录，兼顾页面返回刷新与杀后台后的持久化恢复。
    if (!AppStorage.Set('importedCoursesJson', coursesJson)) {
      AppStorage.SetOrCreate('importedCoursesJson', coursesJson);
    }
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const filePath = `${context.filesDir}/${this.courseFileName}`;
      const file = fs.openSync(filePath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, coursesJson);
      fs.closeSync(file);
    } catch (error) {
      this.parseStatus = '课表已导入，但本地文件保存失败。';
      this.parsePreview = JSON.stringify(error);
    }
    afterSave();
  }

  private flattenImportedText(text: string): string {
    // 正方页面的文本可能混有换行、制表符和不间断空格，先压平成稳定格式再解析。
    return (text ? text : '')
      .replace(/\u00a0/g, ' ')
      .replace(/\r/g, '\n')
      .replace(/[ \t]+/g, ' ')
      .replace(/\n+/g, ' ')
      .trim();
  }

  private findDayBefore(text: string, index: number, fallbackDay: number): number {
    const dayNames: string[] = ['星期一', '星期二', '星期三', '星期四', '星期五', '星期六', '星期日', '星期天'];
    let bestIndex: number = -1;
    let day: number = fallbackDay;

    dayNames.forEach((dayName: string, dayIndex: number) => {
      const foundIndex: number = text.lastIndexOf(dayName, index);
      if (foundIndex > bestIndex) {
        bestIndex = foundIndex;
        day = dayIndex === 7 ? 6 : dayIndex;
      }
    });

    return day;
  }

  private dedupeImportedCourses(courses: ImportedCourse[]): ImportedCourse[] {
    // 保留同名课程在不同周几/节次的多次出现，只去掉完全相同的重复项。
    const seenKeys: string[] = [];
    const result: ImportedCourse[] = [];

    courses.forEach((course: ImportedCourse) => {
      const normalizedCourse: ImportedCourse = this.normalizeImportedCourse(course);
      const key: string = `${normalizedCourse.day}|${normalizedCourse.startSection}|${normalizedCourse.endSection}|${normalizedCourse.name}|${normalizedCourse.detail}`;
      if (seenKeys.indexOf(key) < 0) {
        seenKeys.push(key);
        result.push(normalizedCourse);
      }
    });

    return result;
  }

  private normalizeImportedCourse(course: ImportedCourse): ImportedCourse {
    // 去掉课程名里夹带的周几、节次、星标和教学元信息，避免卡片标题过长。
    let name: string = this.flattenImportedText(course.name)
      .replace(/^(星期[一二三四五六日天]|周[一二三四五六日天])\s*/, '')
      .replace(/^第?\s*\d{1,2}\s*[-至~－—]\s*\d{1,2}\s*节?\s*/, '')
      .replace(/^[★☆■]\s*/, '')
      .trim();

    name = name
      .split(/周数|校区|上课地点|教师|教学班|考核方式|备注/)[0]
      .replace(/[★☆■].*$/, '')
      .trim();

    return {
      day: course.day,
      startSection: course.startSection,
      endSection: course.endSection,
      name: name.length > 0 ? name : course.name,
      detail: this.normalizeImportedDetail(course.detail)
    };
  }

  private normalizeImportedDetail(detail: string): string {
    return detail
      .split('|')
      .map((part: string) => {
        return this.flattenImportedText(part)
          .replace(/教学班.*$/, '')
          .replace(/教学班组成.*$/, '')
          .replace(/\(\d{4}\s*[-－]\s*\d{4}\s*[-－]\s*\d\).*$/, '')
          .trim();
      })
      .filter((part: string) => {
        return part.length > 0;
      })
      .join(' | ');
  }

  private recoverCoursesFromText(text: string, fallbackDay: number = -1): ImportedCourse[] {
    // 兜底解析：当表格结构不稳定时，从整段文本中按“节次 + 课程名 + 周数”恢复课程。
    const source: string = this.flattenImportedText(text);
    const titlePattern: RegExp = /(?:^|\s|##\s*|星期[一二三四五六日天]\s*)(\d{1,2})\s*[-至~－—]\s*(\d{1,2})(?!\s*周)\s*(?:节)?\s*([^★☆■\n\r]{1,50})/g;
    const indexes: number[] = [];
    const startSections: number[] = [];
    const endSections: number[] = [];
    const names: string[] = [];

    let match = titlePattern.exec(source);
    while (match !== null) {
      const startSection: number = Number(match[1]);
      const endSection: number = Number(match[2]);
      const name: string = this.flattenImportedText(match[3])
        .split(/周数|校区|上课地点|教师|教学班|考核方式|备注/)[0]
        .replace(/^节\s*/, '')
        .trim();

      if (startSection >= 1 && startSection <= 11 && endSection >= startSection && endSection <= 11 && name.length > 0 && name.length <= 40) {
        indexes.push(match.index);
        startSections.push(startSection);
        endSections.push(endSection);
        names.push(name);
      }

      match = titlePattern.exec(source);
    }

    const courses: ImportedCourse[] = [];
    for (let index = 0; index < indexes.length; index++) {
      const blockStart: number = indexes[index];
      const blockEnd: number = index + 1 < indexes.length ? indexes[index + 1] : source.length;
      const block: string = source.substring(blockStart, blockEnd);
      const day: number = this.findDayBefore(source, blockStart, fallbackDay);

      if (day < 0) {
        continue;
      }

      const weeksMatch = block.match(/周数\s*[:：]\s*([0-9,，\s\-－至单双周]+)/);
      const campusMatch = block.match(/校区\s*[:：]\s*([\u4e00-\u9fa5]{2,12}校区)/);
      const roomMatch = block.match(/上课地点\s*[:：]\s*([A-Za-z0-9\-－]+)/);
      const teacherMatch = block.match(/教师\s*[:：]\s*([\u4e00-\u9fa5]{2,8})/);
      const typeMatch = block.match(/[★☆■]/);
      const detailParts: string[] = [];

      if (weeksMatch) {
        detailParts.push(weeksMatch[1].replace(/\s+/g, ''));
      }
      if (campusMatch || roomMatch) {
        detailParts.push(`${campusMatch ? campusMatch[1] : ''}${roomMatch ? ' ' + roomMatch[1] : ''}`.trim());
      }
      if (teacherMatch) {
        detailParts.push(teacherMatch[1]);
      }
      if (typeMatch) {
        detailParts.push(typeMatch[0]);
      }

      courses.push({
        day: day,
        startSection: startSections[index],
        endSection: endSections[index],
        name: names[index],
        detail: detailParts.join(' | ')
      });
    }

    return this.dedupeImportedCourses(courses);
  }

  private parseListSchedule(): void {
    // 注入到 WebView 的脚本会优先解析正方列表课表，再自动保存为本地课程 JSON。
    const listScanner: string = `
      (function () {
        try {
          function toArray(list) {
            return list ? Array.prototype.slice.call(list) : [];
          }

          function cleanText(text) {
            return (text || '').replace(/\\u00a0/g, ' ').replace(/\\r/g, '\\n').replace(/[ \\t]+/g, ' ').replace(/\\n\\s+/g, '\\n').trim();
          }

          function flatText(text) {
            return cleanText(text).replace(/\\n+/g, ' ');
          }

          function getCells(row) {
            return toArray(row && (row.cells || row.children)).filter(function (cell) {
              return /td|th/i.test(cell.tagName || '');
            });
          }

          function dayOf(text) {
            var value = flatText(text);
            var days = [
              ['星期一', '周一', '星期1'],
              ['星期二', '周二', '星期2'],
              ['星期三', '周三', '星期3'],
              ['星期四', '周四', '星期4'],
              ['星期五', '周五', '星期5'],
              ['星期六', '周六', '星期6'],
              ['星期日', '星期天', '周日', '周天', '星期7']
            ];

            for (var i = 0; i < days.length; i++) {
              for (var j = 0; j < days[i].length; j++) {
                if (value.indexOf(days[i][j]) >= 0) {
                  return i;
                }
              }
            }

            return -1;
          }

          function dayLabelOf(text) {
            var match = flatText(text).match(/星期[一二三四五六日天]|周[一二三四五六日天]/);
            return match ? match[0] : '';
          }

          function parseSection(text) {
            var value = flatText(text);
            var range = value.match(/(?:第)?\\s*(\\d{1,2})\\s*[-至~－—]\\s*(\\d{1,2})\\s*节/);
            if (!range) {
              range = value.match(/(?:^|\\s|星期[一二三四五六日天]\\s*|周[一二三四五六日天]\\s*)(\\d{1,2})\\s*[-至~－—]\\s*(\\d{1,2})(?!\\s*周)(?=\\s|[\\u4e00-\\u9fa5]|[★☆■]|$)/);
            }
            if (range) {
              return {
                start: parseInt(range[1], 10),
                end: parseInt(range[2], 10)
              };
            }

            var single = value.match(/(?:第)?\\s*(\\d{1,2})\\s*节/);
            if (single) {
              var section = parseInt(single[1], 10);
              return {
                start: section,
                end: section
              };
            }

            return null;
          }

          function isHeaderText(text) {
            var value = flatText(text);
            if (!value) {
              return true;
            }
            if (/[★☆■]/.test(value) || /周数\s*[:：]|上课地点\s*[:：]|教师\s*[:：]/.test(value)) {
              return false;
            }
            return /^(星期|周|节次|课表信息|课程信息|上课地点|教师|时间段|时间|上午|下午|晚上)$/.test(value) ||
              (/学年|查询|打印|导出|课表查询|课程名称|教学班|红色斜体/.test(value) &&
                !/\d{1,2}\s*[-至~－—]\s*\d{1,2}(?!\s*周)/.test(value));
          }

          function parseCourse(rawText, dayText, sectionText) {
            var raw = flatText(rawText);
            if (!raw || isHeaderText(raw)) {
              return null;
            }

            var day = dayOf(dayText + ' ' + raw);
            var sectionRange = parseSection(raw) || parseSection(sectionText + ' ' + raw);
            if (day < 0 || !sectionRange) {
              return null;
            }

            if (sectionRange.start < 1 || sectionRange.start > 11 || sectionRange.end < sectionRange.start || sectionRange.end > 11) {
              return null;
            }

            var name = '';
            var titleMatch = raw.match(/^\\s*(?:##\\s*)?(?:(?:星期[一二三四五六日天]|周[一二三四五六日天])\\s*)?(?:第)?\\s*\\d{1,2}\\s*[-至~－—]\\s*\\d{1,2}(?!\\s*周)\\s*节?\\s*([^★☆■\\n\\r]+)/);
            if (titleMatch) {
              name = flatText(titleMatch[1]);
            }

            var body = raw;
            var startAfterSection = body.match(/^\\s*(?:##\\s*)?(?:(?:星期[一二三四五六日天]|周[一二三四五六日天])\\s*)?\\d{1,2}\\s*[-至~－—]\\s*\\d{1,2}(?!\\s*周)\\s*节?\\s*(.+)/);
            if (startAfterSection && /学年|学期|课表|学号|星期|周[一二三四五六日天]/.test(body)) {
              body = startAfterSection[1];
            }
            body = body
              .replace(/星期[一二三四五六日天]/g, ' ')
              .replace(/周[一二三四五六日天]/g, ' ')
              .replace(/(?:第)?\\s*\\d{1,2}\\s*[-至~－—]\\s*\\d{1,2}\\s*节/g, ' ')
              .replace(/(?:^|\\s)\\d{1,2}\\s*[-至~－—]\\s*\\d{1,2}(?!\\s*周)(?=\\s|[\\u4e00-\\u9fa5]|[★☆■]|$)/g, ' ')
              .replace(/(?:第)?\\s*\\d{1,2}\\s*节/g, ' ')
              .replace(/课表信息|课程信息|节次|星期/g, ' ');
            body = flatText(body);

            var nameByMark = body.match(/^(.+?)[★☆■]/);
            if (!name && nameByMark) {
              name = flatText(nameByMark[1]);
            }

            if (!name) {
              var nameBySection = body.match(/^(.+?)\\s*\\(\\s*\\d{1,2}\\s*[-至~－—]\\s*\\d{1,2}\\s*节\\s*\\)/);
              if (nameBySection) {
                name = flatText(nameBySection[1]);
              }
            }

            if (!name) {
              var beforeWeek = body.split(/\\d{1,2}\\s*[-至~－—]\\s*\\d{1,2}\\s*周/)[0];
              name = flatText(beforeWeek.replace(/\\(.*$/, ''));
            }

            name = name.replace(/[★☆■].*$/, '').trim();
            name = name.replace(/^节\\s*/, '').trim();
            name = name.replace(/^\\d{1,2}\\s*[-至~－—]\\s*\\d{1,2}\\s*/, '').trim();
            if (!name || name.length > 40 || isHeaderText(name)) {
              return null;
            }

            var weeksMatch = raw.match(/周数\\s*[:：]\\s*([0-9,，\\s至\\-－单双周]+)/) || raw.match(/\\d{1,2}(?:\\s*[-至~－—]\\s*\\d{1,2})?(?:\\s*[,，]\\s*\\d{1,2}(?:\\s*[-至~－—]\\s*\\d{1,2})?)*\\s*(?:单|双)?周/);
            var campusMatch = raw.match(/校区\\s*[:：]\\s*([\\u4e00-\\u9fa5]{2,12}校区)/);
            var roomMatch = raw.match(/上课地点\\s*[:：]\\s*([A-Za-z0-9\\-－]+)/);
            var locationMatch = raw.match(/([\\u4e00-\\u9fa5]{2,12}校区\\s*[A-Za-z0-9\\-－]+(?:\\s*[A-Za-z0-9\\-－]+)?)/);
            var teacherMatch = raw.match(/教师\\s*[:：]\\s*([\\u4e00-\\u9fa5]{2,8}?)(?=教学班|考核方式|备注|课程|学分|周学时|总学时|$|\\s|[（(])/) ||
              raw.match(/([\\u4e00-\\u9fa5]{2,8})\\s*\\(\\d{4}\\s*[-－]\\s*\\d{4}\\s*[-－]\\s*\\d\\)/);
            var typeMatch = raw.match(/[★☆■]/);

            var detailParts = [];
            if (weeksMatch) {
              detailParts.push((weeksMatch[1] ? weeksMatch[1] : weeksMatch[0]).replace(/\\s+/g, ''));
            }
            if (campusMatch || roomMatch) {
              detailParts.push(((campusMatch ? campusMatch[1] : '') + (roomMatch ? ' ' + roomMatch[1] : '')).trim());
            } else if (locationMatch) {
              detailParts.push(locationMatch[1].replace(/\\s+/g, ' '));
            }
            if (teacherMatch) {
              detailParts.push(teacherMatch[1]);
            }
            if (typeMatch) {
              detailParts.push(typeMatch[0]);
            }

            return {
              day: day,
              startSection: sectionRange.start,
              endSection: sectionRange.end,
              name: name,
              detail: detailParts.length > 0 ? detailParts.join(' | ') : raw
            };
          }

          function pickCourseText(texts, dayText, sectionText) {
            var candidates = texts.filter(function (text) {
              var value = flatText(text);
              return value && value !== flatText(dayText) && value !== flatText(sectionText) && !isHeaderText(value);
            });

            candidates.sort(function (left, right) {
              return flatText(right).length - flatText(left).length;
            });

            return candidates.length > 0 ? candidates[0] : '';
          }

          function isPossibleCourseText(text) {
            var value = flatText(text);
            return /[★☆■]/.test(value) ||
              /\\(\\s*\\d{1,2}\\s*[-至~－—]\\s*\\d{1,2}\\s*节\\s*\\)/.test(value) ||
              /(?:^|\\s)\\d{1,2}\\s*[-至~－—]\\s*\\d{1,2}(?!\\s*周)(?=\\s|[\\u4e00-\\u9fa5]|[★☆■])/.test(value) ||
              /\\d{1,2}\\s*[-至~－—]\\s*\\d{1,2}\\s*周/.test(value);
          }

          function splitSameSlotCourses(text) {
            var value = flatText(text);
            var starts = [];
            var markPattern = /[★☆■](?=\\s*(?:周数\\s*[:：]|\\(|\\d{1,2}\\s*[-至~－—]\\s*\\d{1,2}\\s*周|校区|上课地点|$))/g;
            var match = markPattern.exec(value);

            while (match) {
              var titleStart = value.lastIndexOf(' ', match.index);
              var metaPattern = /(?:学分|总学时|周学时)\\s*[:：]\\s*\\d+(?:\\.\\d)?/g;
              var metaMatch = metaPattern.exec(value);
              var metaEnd = -1;

              while (metaMatch && metaMatch.index < match.index) {
                metaEnd = metaMatch.index + metaMatch[0].length;
                metaMatch = metaPattern.exec(value);
              }

              starts.push(metaEnd >= 0 ? metaEnd : (titleStart >= 0 ? titleStart + 1 : 0));
              match = markPattern.exec(value);
            }

            var parts = [];
            for (var index = 0; index < starts.length; index++) {
              var start = starts[index];
              var end = index + 1 < starts.length ? starts[index + 1] : value.length;
              parts.push(value.slice(start, end));
            }

            return parts.length > 0 ? parts : [value];
          }

          function parseSlotCourses(dayText, sectionText, courseText) {
            var result = [];
            splitSameSlotCourses(courseText).forEach(function (block) {
              var course = parseCourse(block, dayText, sectionText);
              if (course) {
                result.push(course);
              }
            });
            return result;
          }

          function removeDayAndSectionText(text) {
            return flatText(text)
              .replace(/星期[一二三四五六日天]|周[一二三四五六日天]/g, ' ')
              .replace(/(?:第)?\\s*\\d{1,2}\\s*[-至~－—]\\s*\\d{1,2}(?!\\s*周)(?=\\s|[\\u4e00-\\u9fa5]|[★☆■]|$)\\s*节?/g, ' ')
              .replace(/(?:第)?\\s*\\d{1,2}\\s*节/g, ' ')
              .trim();
          }

          function pickRowParts(texts, rowText) {
            var dayText = '';
            var sectionText = '';
            var dayCellIndex = -1;
            var sectionCellIndex = -1;
            var sectionRange = null;

            texts.forEach(function (text, index) {
              if (dayCellIndex < 0 && dayOf(text) >= 0 && flatText(text).length <= 15) {
                dayCellIndex = index;
                dayText = dayLabelOf(text);
              }
            });

            texts.forEach(function (text, index) {
              var currentSection = parseSection(text);
              if (!currentSection) {
                return;
              }

              var previousSectionText = sectionCellIndex >= 0 && texts[sectionCellIndex] ? texts[sectionCellIndex] : '';
              var shouldUse = sectionCellIndex < 0 ||
                index === dayCellIndex ||
                index === dayCellIndex + 1 ||
                flatText(text).length < flatText(previousSectionText).length;

              if (shouldUse) {
                sectionCellIndex = index;
                sectionRange = currentSection;
              }
            });

            if (!dayText && dayOf(rowText) >= 0 && flatText(rowText).length <= 15) {
              dayText = dayLabelOf(rowText);
            }

            if (sectionRange) {
              sectionText = sectionRange.start + '-' + sectionRange.end;
            } else {
              var rowSection = parseSection(rowText);
              if (rowSection) {
                sectionText = rowSection.start + '-' + rowSection.end;
              }
            }

            var courseParts = [];
            texts.forEach(function (text, index) {
              var candidate = text;
              if (index === dayCellIndex || index === sectionCellIndex) {
                candidate = removeDayAndSectionText(candidate);
              }

              if (!candidate || isHeaderText(candidate)) {
                return;
              }

              if (isPossibleCourseText(candidate) || (index !== dayCellIndex && index !== sectionCellIndex)) {
                courseParts.push(candidate);
              }
            });

            return {
              dayText: dayText,
              sectionText: sectionText,
              courseText: courseParts.join('\\n')
            };
          }

          function dedupe(courses) {
            var seen = {};
            var result = [];
            courses.forEach(function (course) {
              var cleanName = flatText(course.name)
                .replace(/^(星期[一二三四五六日天]|周[一二三四五六日天])\\s*/, '')
                .replace(/^第?\\s*\\d{1,2}\\s*[-至~－—]\\s*\\d{1,2}\\s*节?\\s*/, '')
                .replace(/[★☆■].*$/, '')
                .trim();
              var key = [course.day, course.startSection, course.endSection, cleanName, course.detail].join('|');
              if (!seen[key]) {
                seen[key] = true;
                course.name = cleanName || course.name;
                result.push(course);
              }
            });
            return result;
          }

          function parseFallbackFromText(text) {
            var result = [];
            var value = flatText(text);
            var currentDayText = '';
            var chunks = value
              .replace(/(星期[一二三四五六日天])/g, ' $1 ')
              .split(/(?=(?:星期[一二三四五六日天]\\s*)?\\d{1,2}\\s*[-至~－—]\\s*\\d{1,2}(?!\\s*周)(?=\\s|[\\u4e00-\\u9fa5]|[★☆■]))/);

            chunks.forEach(function (chunk) {
              var cleanChunk = flatText(chunk);
              if (!cleanChunk) {
                return;
              }

              var dayMatch = cleanChunk.match(/星期[一二三四五六日天]/);
              if (dayMatch) {
                currentDayText = dayMatch[0];
              }

              if (!isPossibleCourseText(cleanChunk)) {
                return;
              }

              var course = parseCourse(cleanChunk, currentDayText, cleanChunk);
              if (course) {
                result.push(course);
              }
            });

            return result;
          }

          function parseBlocksFromText(text) {
            var result = [];
            var source = cleanText(text);
            var currentDayText = '';
            var titlePattern = /(?:^|\\s|##\\s*|星期[一二三四五六日天]\\s*)(\\d{1,2})\\s*[-至~－—]\\s*(\\d{1,2})(?!\\s*周)\\s*节?\\s*([^\\n\\r★]+)/g;
            var matches = [];
            var match = titlePattern.exec(source);

            while (match) {
              matches.push({
                index: match.index,
                text: match[0]
              });
              match = titlePattern.exec(source);
            }

            for (var i = 0; i < matches.length; i++) {
              var start = matches[i].index;
              var end = i + 1 < matches.length ? matches[i + 1].index : source.length;
              var block = source.slice(start, end);
              var dayMatch = block.match(/星期[一二三四五六日天]/);

              if (!dayMatch) {
                var before = source.slice(0, start);
                var dayMatches = before.match(/星期[一二三四五六日天]/g);
                if (dayMatches && dayMatches.length > 0) {
                  currentDayText = dayMatches[dayMatches.length - 1];
                }
              } else {
                currentDayText = dayMatch[0];
              }

              var course = parseCourse(block, currentDayText, block);
              if (course) {
                result.push(course);
              }
            }

            return result;
          }

          function parseListTextTable(text) {
            var result = [];
            var source = cleanText(text)
              .replace(/(星期[一二三四五六日天]|周[一二三四五六日天])/g, '\\n$1')
              .replace(/((?:学分|总学时|周学时)\\s*[:：]\\s*\\d+(?:\\.\\d)?)(?=(?:星期[一二三四五六日天]|周[一二三四五六日天])?\\s*\\d{1,2}\\s*[-至~－—]\\s*\\d{1,2}(?!\\s*周))/g, '$1\\n')
              .replace(/((?:学分|总学时|周学时)\\s*[:：]\\s*\\d+(?:\\.\\d)?)\\s+(?=(?:星期[一二三四五六日天]|周[一二三四五六日天]))/g, '$1\\n');
            var currentDayText = '';
            var anchors = [];
            var anchorPattern = /(?:^|\\s)(星期[一二三四五六日天]|周[一二三四五六日天])?\\s*(\\d{1,2})\\s*[-至~－—]\\s*(\\d{1,2})(?!\\s*周)(?=\\s|[\\u4e00-\\u9fa5]|[【★☆■]|$)/g;
            var match = anchorPattern.exec(source);

            while (match) {
              var startSection = parseInt(match[2], 10);
              var endSection = parseInt(match[3], 10);

              if (match[1]) {
                currentDayText = match[1];
              }

              if (currentDayText && startSection >= 1 && startSection <= 11 && endSection >= startSection && endSection <= 11) {
                anchors.push({
                  index: match.index,
                  dayText: currentDayText,
                  sectionText: startSection + '-' + endSection
                });
              }

              match = anchorPattern.exec(source);
            }

            anchors.forEach(function (anchor, index) {
              var nextIndex = index + 1 < anchors.length ? anchors[index + 1].index : source.length;
              var block = source.slice(anchor.index, nextIndex);

              splitSameSlotCourses(block).forEach(function (courseBlock) {
                var course = parseCourse(courseBlock, anchor.dayText, anchor.sectionText);
                if (course) {
                  var blockDayMatch = flatText(courseBlock).match(/^(星期[一二三四五六日天]|周[一二三四五六日天])/);
                  var blockDay = blockDayMatch ? dayOf(blockDayMatch[1]) : -1;
                  course.day = blockDay >= 0 ? blockDay : dayOf(anchor.dayText);
                  var section = parseSection(courseBlock) || parseSection(anchor.sectionText);
                  if (section) {
                    course.startSection = section.start;
                    course.endSection = section.end;
                  }
                  result.push(course);
                }
              });
            });

            return dedupe(result);
          }

          function parseGridTable() {
            var gridTable = document.querySelector('#kbgrid_table_0');
            var result = {
              courses: [],
              samples: []
            };

            if (!gridTable) {
              return result;
            }

            var rows = toArray(gridTable.querySelectorAll('tr'));
            var headerIndex = -1;
            var dayLabels = ['星期一', '星期二', '星期三', '星期四', '星期五', '星期六', '星期日'];

            rows.forEach(function (row, index) {
              var text = flatText(row.innerText || row.textContent || '');
              if (headerIndex < 0 && /星期一|周一/.test(text) && /星期日|星期天|周日|周天/.test(text)) {
                headerIndex = index;
              }
            });

            if (headerIndex < 0) {
              return result;
            }

            rows.slice(headerIndex + 1).forEach(function (row, rowOffset) {
              var cells = getCells(row);
              if (cells.length < 7) {
                return;
              }

              var sectionText = '';
              cells.some(function (cell) {
                var text = flatText(cell.innerText || cell.textContent || '');
                if (/^\\d{1,2}$/.test(text)) {
                  var section = parseInt(text, 10);
                  if (section >= 1 && section <= 11) {
                    sectionText = section + '-' + section;
                    return true;
                  }
                }
                return false;
              });

              if (!sectionText) {
                var fallbackSection = Math.min(11, rowOffset + 1);
                sectionText = fallbackSection + '-' + fallbackSection;
              }

              var dayCells = cells.slice(Math.max(0, cells.length - 7));
              dayCells.forEach(function (cell, dayIndex) {
                var rawText = cleanText(cell.innerText || cell.textContent || '');
                if (!isPossibleCourseText(rawText) || isHeaderText(rawText)) {
                  return;
                }

                var blockNodes = toArray(cell.querySelectorAll ? cell.querySelectorAll('.kbcontent, .kbcontent1, [class*=kbcontent], [id*=kbcontent]') : []);
                var blocks = [];

                blockNodes.forEach(function (node) {
                  var blockText = cleanText(node.innerText || node.textContent || '');
                  if (isPossibleCourseText(blockText) && !isHeaderText(blockText)) {
                    blocks.push(blockText);
                  }
                });

                if (blocks.length === 0) {
                  blocks = splitSameSlotCourses(rawText);
                }

                blocks.forEach(function (block) {
                  var cleanBlock = flatText(block);
                  if (!isPossibleCourseText(cleanBlock) || isHeaderText(cleanBlock)) {
                    return;
                  }

                  var blockSection = parseSection(cleanBlock);
                  var course = parseCourse(cleanBlock, dayLabels[dayIndex], blockSection ? cleanBlock : sectionText);
                  if (course) {
                    result.samples.push(cleanBlock.slice(0, 500));
                    result.courses.push(course);
                  }
                });
              });
            });

            result.courses = dedupe(result.courses);
            return result;
          }

          function courseGridKey(course) {
            var detailParts = flatText(course.detail).split('|').map(function (part) {
              return flatText(part);
            });
            var weekText = detailParts.length > 0 ? detailParts[0] : '';
            var typeMatch = flatText(course.detail).match(/[★☆■]/);

            return [
              flatText(course.name).replace(/[★☆■].*$/, '').trim(),
              weekText,
              typeMatch ? typeMatch[0] : ''
            ].join('|');
          }

          function mergeGridFirstCourses(listCourses, gridCourses) {
            if (gridCourses.length === 0) {
              return listCourses;
            }

            if (listCourses.length === 0) {
              return gridCourses;
            }

            var gridKeys = {};
            var merged = gridCourses.slice();

            gridCourses.forEach(function (course) {
              var key = courseGridKey(course);
              gridKeys[key] = true;
            });

            listCourses.forEach(function (course) {
              var key = courseGridKey(course);
              if (!gridKeys[key]) {
                merged.push(course);
              }
            });

            return dedupe(merged);
          }

          var table = document.querySelector('#kblist_table');
          var courses = [];
          var samples = [];
          var textCourses = table ? parseListTextTable(table.innerText || table.textContent || '') : [];
          var lastDayText = '';
          var lastSectionText = '';

          if (table) {
            toArray(table.querySelectorAll('tr')).forEach(function (row) {
              var texts = getCells(row).map(function (cell) {
                return cleanText(cell.innerText || cell.textContent || '');
              }).filter(function (text) {
                return flatText(text).length > 0;
              });
              var rowText = cleanText(row.innerText || row.textContent || texts.join('\\n'));

              if (texts.length === 0 && flatText(rowText).length === 0) {
                return;
              }

              var rowParts = pickRowParts(texts, rowText);
              var dayText = rowParts.dayText;
              var sectionText = rowParts.sectionText;
              var courseText = rowParts.courseText;

              if (!dayText && dayOf(rowText) >= 0 && flatText(rowText).length <= 15) {
                dayText = dayLabelOf(rowText);
              }

              if (!sectionText && (dayText || texts.length <= 1)) {
                var sectionFromRow = parseSection(rowText);
                if (sectionFromRow) {
                  sectionText = sectionFromRow.start + '-' + sectionFromRow.end;
                }
              }

              var sectionFromCourse = parseSection(courseText);
              if (sectionFromCourse) {
                sectionText = sectionFromCourse.start + '-' + sectionFromCourse.end;
              }

              if (dayText) {
                lastDayText = dayText;
              } else {
                dayText = lastDayText;
              }

              if (sectionText) {
                lastSectionText = sectionText;
              } else {
                sectionText = lastSectionText;
              }

              if (!courseText || !isPossibleCourseText(courseText)) {
                courseText = rowText;
              }

              if (!isPossibleCourseText(courseText)) {
                return;
              }

              if (courseText) {
                var sampleText = flatText(courseText);
                if (dayText && dayOf(sampleText) < 0) {
                  sampleText = dayText + ' ' + sampleText;
                }
                if (sectionText && !parseSection(sampleText)) {
                  sampleText = sectionText + ' ' + sampleText;
                }
                samples.push(flatText(sampleText).slice(0, 500));
              }

              var slotCourses = parseSlotCourses(dayText, sectionText, courseText);
              slotCourses.forEach(function (course) {
                courses.push(course);
              });
            });

            if (courses.length === 0) {
              courses = courses.concat(parseBlocksFromText(table.innerText || table.textContent || ''));
            }

            if (courses.length === 0) {
              courses = courses.concat(parseFallbackFromText(table.innerText || table.textContent || ''));
            }

            if (courses.length === 0 && samples.length > 0) {
              courses = courses.concat(parseBlocksFromText(samples.join('\\n')));
            }

            if (courses.length === 0 && samples.length > 0) {
              courses = courses.concat(parseFallbackFromText(samples.join(' ')));
            }
          }

          var usingTextCourses = textCourses.length > 0;
          var usingRowCourses = courses.length > 0;
          if (usingTextCourses && usingRowCourses) {
            courses = dedupe(courses.concat(textCourses));
          } else if (usingTextCourses) {
            courses = textCourses;
          }

          return JSON.stringify({
            source: usingTextCourses && usingRowCourses ? 'kblist_table_rows_text' : (usingTextCourses ? 'kblist_table_text' : 'kblist_table_rows'),
            tableCount: document.querySelectorAll('table').length,
            courseCellCount: samples.length,
            samples: samples,
            courses: dedupe(courses)
          });
        } catch (error) {
          return JSON.stringify({
            source: 'kblist_table',
            tableCount: document.querySelectorAll('table').length,
            courseCellCount: 0,
            parseError: error && error.message ? error.message : String(error),
            samples: [],
            courses: []
          });
        }
      })();
    `;

    try {
      this.webController.runJavaScript(listScanner, (error, result) => {
        if (error) {
          this.parseStatus = '解析失败：无法读取当前网页。';
          this.parsePreview = JSON.stringify(error);
          return;
        }

        try {
          let decoded = JSON.parse(result || '{}') as ZhengfangParseResult | string;
          if (typeof decoded === 'string') {
            decoded = JSON.parse(decoded || '{}') as ZhengfangParseResult;
          }
          const parsed = decoded as ZhengfangParseResult;
          let courses: ImportedCourse[] = parsed.courses ? parsed.courses : [];
          const samples: string[] = parsed.samples ? parsed.samples : [];
          const tableCount: number = parsed.tableCount ? parsed.tableCount : 0;
          const courseCellCount: number = parsed.courseCellCount ? parsed.courseCellCount : 0;

          if (parsed.parseError) {
            this.parseStatus = `解析失败：${parsed.parseError}`;
            this.parsePreview = JSON.stringify(parsed, null, 2);
            return;
          }

          if (courses.length === 0 && samples.length > 0) {
            const recoveredCourses: ImportedCourse[] = this.recoverCoursesFromText(samples.join('\n'));
            if (recoveredCourses.length > 0) {
              courses = recoveredCourses;
            }
          }

          courses = this.dedupeImportedCourses(courses);

          if (courses.length === 0) {
            this.parseStatus = `未识别到课表课程。已扫描 ${tableCount} 个表格、${courseCellCount} 条疑似明细。`;
            this.parsePreview = samples.length > 0 ? samples.join('\n\n') : JSON.stringify(parsed, null, 2);
            return;
          }

          const coursesJson: string = JSON.stringify(courses);
          this.saveImportedCourses(coursesJson, () => {
            this.parseStatus = `已从明细表导入 ${courses.length} 门课程，并已保存到本地。`;
            this.parsePreview = courses.map((course: ImportedCourse) => {
              return `${course.name} 周${course.day + 1} 第${course.startSection}-${course.endSection}节 ${course.detail}`;
            }).join('\n');
            router.back();
          });
        } catch (parseError) {
          this.parseStatus = '解析失败：网页返回内容格式不正确。';
          this.parsePreview = `${result}\n${JSON.stringify(parseError)}`;
        }
      });
    } catch (error) {
      this.parseStatus = '解析失败：执行网页脚本时出错。';
      this.parsePreview = JSON.stringify(error);
    }
  }

  private parseSchedule(): void {
    const zhengfangScanner: string = `
      (function () {
        try {
        function cleanText(text) {
          return (text || '').replace(/\\r/g, '\\n').replace(/[ \\t]+/g, ' ').replace(/\\n\\s+/g, '\\n').trim();
        }

        function flatText(text) {
          return cleanText(text).replace(/\\n+/g, ' ');
        }

        function toArray(list) {
          return list ? Array.prototype.slice.call(list) : [];
        }

        function safeQueryAll(root, selector) {
          if (!root || !root.querySelectorAll) {
            return [];
          }

          return toArray(root.querySelectorAll(selector));
        }

        function getRowCells(row) {
          if (!row) {
            return [];
          }

          return toArray(row.cells || row.children).filter(function (cell) {
            return /td|th/i.test(cell.tagName);
          });
        }

        function isHeaderText(text) {
          return /^(周一|周二|周三|周四|周五|周六|周日|星期一|星期二|星期三|星期四|星期五|星期六|星期日|节次|时间|上午|下午|晚上)$/i.test(flatText(text)) ||
            /^(节\\/周|上课地点|教师|教师姓名|学分|学时|课程号|教学班|校区|课堂|容量|选课人数)$/i.test(flatText(text)) ||
            /学年|学期|查询|打印|导出|返回|菜单|首页|课程名称|课表查询/.test(flatText(text));
        }

        function isUsefulCourseText(text) {
          var clean = flatText(text);
          return clean.length >= 2 && clean.length <= 260 && !isHeaderText(clean);
        }

        function getElementLines(element) {
          if (!element) {
            return [];
          }

          var html = element.innerHTML || '';
          var text = html
            .replace(/<br\\s*\\/?\\s*>/gi, '\\n')
            .replace(/<\\/p>|<\\/div>|<\\/li>|<\\/span>/gi, '\\n')
            .replace(/<[^>]+>/g, '')
            .replace(/&nbsp;/g, ' ')
            .replace(/&amp;/g, '&')
            .replace(/&lt;/g, '<')
            .replace(/&gt;/g, '>');

          return cleanText(text)
            .split(/\\n+/)
            .map(flatText)
            .filter(function (line) {
              return line.length > 0 && !isHeaderText(line);
            });
        }

        function splitCourseBlocksFromLines(lines) {
          if (lines.length === 0) {
            return [];
          }

          var blocks = [];
          var current = [];

          lines.forEach(function (line) {
            var looksLikeName = line.length <= 45 &&
              !isHeaderText(line) &&
              !/周|星期|节|教师|老师|教室|校区|地点|楼|室|学分|上课|停课|考试|\\d{1,2}:\\d{2}/.test(line) &&
              !/^\\d+$/.test(line);
            var currentText = current.join(' ');
            var currentHasMeta = /周|星期|节|教师|老师|教室|校区|地点|楼|室|学分|\\d{1,2}\\s*[-至~－—]\\s*\\d{1,2}/.test(currentText);

            if (current.length > 0 && looksLikeName && currentHasMeta) {
              blocks.push(current.join('\\n'));
              current = [line];
              return;
            }

            current.push(line);

            if (current.length >= 6) {
              blocks.push(current.join('\\n'));
              current = [];
            }
          });

          if (current.length > 0) {
            blocks.push(current.join('\\n'));
          }

          return blocks.filter(isUsefulCourseText);
        }

        function getCellDirectLines(cell) {
          var directTexts = [];
          var children = toArray(cell ? cell.children : []);

          if (children.length === 0) {
            return getElementLines(cell);
          }

          children.forEach(function (child) {
            var text = flatText(child.innerText || child.textContent || '');

            if (text.length > 0 && !isHeaderText(text)) {
              directTexts.push(text);
            }
          });

          return directTexts.length > 0 ? directTexts : getElementLines(cell);
        }

        function getCourseBlocksFromCell(cell) {
          var blockNodes = safeQueryAll(cell, '.kbcontent, .kbcontent1, [class*=kbcontent], [id*=kbcontent]');

          if (blockNodes.length > 0) {
            var nodeBlocks = [];

            blockNodes.forEach(function (node) {
              nodeBlocks = nodeBlocks.concat(splitCourseBlocksFromLines(getElementLines(node)));
            });

            if (nodeBlocks.length > 0) {
              return nodeBlocks;
            }
          }

          return splitCourseBlocksFromLines(getCellDirectLines(cell));
        }

        function getRawCourseTextFromCell(cell) {
          if (!cell) {
            return '';
          }

          var text = cell.innerText || cell.textContent || '';

          return cleanText(text)
            .split(/\\n+/)
            .map(flatText)
            .filter(function (line) {
              return line.length > 0 && !isHeaderText(line);
            })
            .join('\\n');
        }

        function isCourseCellText(text) {
          var clean = flatText(text);

          if (clean.length < 3 || isHeaderText(clean)) {
            return false;
          }

          return /\\d+\\s*[-至~－—]\\s*\\d+\\s*节|\\d+\\s*[-至~－—]\\s*\\d+\\s*周|教师|老师|航空港|校区|BW-|BS-|H-|实验|理论|学时|考试/.test(clean) ||
            safeQueryAll(document, 'u.title.showJxbtkjl, u.showJxbtkjl').some(function (node) {
              return clean.indexOf(flatText(node.innerText || node.textContent || '')) >= 0;
            });
        }

        function pickCourseName(block) {
          var lines = cleanText(block).split(/\\n+/).map(flatText).filter(Boolean);
          var name = lines.find(function (line) {
            return line.length <= 45 && !isHeaderText(line) && !/周|星期|节|教师|老师|教室|校区|地点|楼|室|学分|上课|停课|考试/.test(line);
          });

          return name || lines[0] || flatText(block).slice(0, 18);
        }

        function pickCourseNameFromCell(cell, block) {
          var titleNode = safeQueryAll(cell, 'u.title.showJxbtkjl, u.showJxbtkjl, .title, [data-jxb_id], [data-jxb-id]').find(function (node) {
            var text = flatText(node.innerText || node.textContent || node.getAttribute('title') || '');
            return text.length > 0 && !isHeaderText(text);
          });

          if (titleNode) {
            return flatText(titleNode.innerText || titleNode.textContent || titleNode.getAttribute('title') || '');
          }

          return pickCourseName(block);
        }

        function pickDetail(block) {
          var lines = cleanText(block).split(/\\n+/).map(flatText).filter(Boolean);
          return lines.filter(function (line) {
            return /教师|老师|教室|校区|地点|楼|室/.test(line);
          }).slice(0, 2).join(' ');
        }

        function parseSection(text, fallbackSection) {
          var clean = flatText(text);
          var match = clean.match(/(?:第)?\\s*(\\d{1,2})\\s*[-至~－—]\\s*(\\d{1,2})\\s*节/);

          if (!match) {
            match = clean.match(/(?:第)?\\s*(\\d{1,2})\\s*节/);
          }

          if (match) {
            var start = Math.max(1, Math.min(11, parseInt(match[1], 10)));
            var end = match[2] ? Math.max(1, Math.min(11, parseInt(match[2], 10))) : start;

            return {
              start: start,
              end: end
            };
          }

          return {
            start: fallbackSection,
            end: fallbackSection
          };
        }

        function parseDay(text, fallbackDay) {
          var dayMatchers = [
            /周一|星期一/,
            /周二|星期二/,
            /周三|星期三/,
            /周四|星期四/,
            /周五|星期五/,
            /周六|星期六/,
            /周日|周天|星期日|星期天/
          ];

          for (var i = 0; i < dayMatchers.length; i++) {
            if (dayMatchers[i].test(text)) {
              return i;
            }
          }

          return fallbackDay;
        }

        function getBestTables() {
          var gridTable = document.querySelector('#kbgrid_table_0');

          if (gridTable) {
            return [gridTable];
          }

          var allTables = safeQueryAll(document, 'table');
          var scored = allTables.map(function (table) {
            var text = flatText(table.innerText || table.textContent);
            var score = 0;

            if (/kbtable|kblist|timetable|course/i.test(table.id + ' ' + table.className)) {
              score += 10;
            }

            if (/周一|星期一/.test(text)) {
              score += 5;
            }

            if (/周二|星期二/.test(text)) {
              score += 3;
            }

            if (/周日|星期日|星期天/.test(text)) {
              score += 3;
            }

            score += safeQueryAll(table, '.kbcontent, .kbcontent1, [class*=kbcontent]').length * 3;
            score += Math.min(10, safeQueryAll(table, 'td').length / 10);

            return {
              table: table,
              score: score
            };
          }).filter(function (item) {
            return item.score >= 5;
          }).sort(function (a, b) {
            return b.score - a.score;
          });

          return scored.length > 0 ? [scored[0].table] : allTables.slice(0, 3);
        }

        function getMainScheduleTable() {
          var gridTable = document.querySelector('#kbgrid_table_0');

          if (gridTable) {
            return gridTable;
          }

          var allTables = safeQueryAll(document, 'table');
          var best = null;
          var bestScore = -1;

          allTables.forEach(function (table) {
            var rows = safeQueryAll(table, 'tr');
            var rowScore = rows.filter(function (row) {
              var cells = getRowCells(row);

              return cells.length >= 8;
            }).length;
            var text = flatText(table.innerText || table.textContent);
            var score = rowScore * 10 +
              (/星期一|周一/.test(text) ? 5 : 0) +
              (/星期日|周日/.test(text) ? 5 : 0) +
              safeQueryAll(table, 'u.title.showJxbtkjl, u.showJxbtkjl, .kbcontent, .kbcontent1, [class*=kbcontent]').length * 3;

            if (score > bestScore) {
              bestScore = score;
              best = table;
            }
          });

          return best;
        }

        var mainScheduleTable = getMainScheduleTable();
        var tables = mainScheduleTable ? [mainScheduleTable] : getBestTables();
        var cells = [];
        var courses = [];

        function addCourse(block, fallbackDay, fallbackSection) {
          var clean = flatText(block);

          if (!isUsefulCourseText(clean)) {
            return;
          }

          var section = parseSection(clean, fallbackSection);
          var day = parseDay(clean, fallbackDay);

          courses.push({
            day: day,
            startSection: section.start,
            endSection: section.end,
            name: pickCourseName(block),
            detail: pickDetail(block)
          });
        }

        function getCellPosition(cell) {
          var row = cell && cell.parentElement ? cell.parentElement : null;
          var table = cell ? cell.closest('table') : null;

          if (!row || !table) {
            return {
              day: 0,
              section: 1
            };
          }

          var rows = safeQueryAll(table, 'tr');
          var bodyRows = rows.filter(function (item) {
            return /td/i.test(item.innerHTML || '');
          });
          var rowIndex = Math.max(0, bodyRows.indexOf(row));
          var rowCells = getRowCells(row);
          var cellIndex = Math.max(0, rowCells.indexOf(cell));
          var firstText = rowCells[0] ? flatText(rowCells[0].innerText || rowCells[0].textContent) : '';
          var sectionMatch = firstText.match(/(?:第)?\\s*(\\d{1,2})\\s*(?:节)?/);
          var day = rowCells.length >= 8 ? cellIndex - (rowCells.length - 7) : cellIndex - 1;

          return {
            day: Math.max(0, Math.min(6, day)),
            section: sectionMatch ? Math.max(1, Math.min(11, parseInt(sectionMatch[1], 10))) : Math.min(11, rowIndex + 1)
          };
        }

        function collectCoursesFromTitleNodes() {
          var titleNodes = safeQueryAll(document, 'u.title.showJxbtkjl, u.showJxbtkjl, .showJxbtkjl[data-jxb_id], .showJxbtkjl[data-jxb-id], [data-jxb_id].title, [data-jxb-id].title');

          titleNodes.forEach(function (node) {
            var titleText = flatText(node.innerText || node.textContent || node.getAttribute('title') || '');

            if (!isUsefulCourseText(titleText) || isHeaderText(titleText)) {
              return;
            }

            var block = node.closest('.kbcontent, .kbcontent1, [class*=kbcontent], [id*=kbcontent]') ||
              node.closest('td') ||
              node.parentElement;
            var cell = node.closest('td');
            var position = getCellPosition(cell);
            var lines = block ? getElementLines(block) : [titleText];
            var blockText = lines.length > 0 ? lines.join('\\n') : titleText;
            var section = parseSection(blockText, position.section);
            var day = parseDay(blockText, position.day);
            var detail = pickDetail(blockText);

            if (detail.length === 0 && lines.length > 1) {
              detail = lines.filter(function (line) {
                return line !== titleText;
              }).slice(0, 2).join(' ');
            }

            cells.push(blockText);
            courses.push({
              day: day,
              startSection: section.start,
              endSection: section.end,
              name: titleText,
              detail: detail
            });
          });
        }

        function buildTableMatrix(table) {
          var matrix = [];
          var rows = safeQueryAll(table, 'tr');

          rows.forEach(function (row, rowIndex) {
            if (!matrix[rowIndex]) {
              matrix[rowIndex] = [];
            }

            var colIndex = 0;

            getRowCells(row).forEach(function (cell) {
              while (matrix[rowIndex][colIndex]) {
                colIndex++;
              }

              var rowSpan = parseInt(cell.getAttribute('rowspan') || '1', 10);
              var colSpan = parseInt(cell.getAttribute('colspan') || '1', 10);

              for (var rowOffset = 0; rowOffset < rowSpan; rowOffset++) {
                var targetRow = rowIndex + rowOffset;

                if (!matrix[targetRow]) {
                  matrix[targetRow] = [];
                }

                for (var colOffset = 0; colOffset < colSpan; colOffset++) {
                  matrix[targetRow][colIndex + colOffset] = cell;
                }
              }

              colIndex += colSpan;
            });
          });

          return matrix;
        }

        function collectCoursesFromGridTable(table) {
          var matrix = buildTableMatrix(table);
          var headerRowIndex = -1;
          var dayColumns = [];
          var dayMatchers = [
            /星期一|周一/,
            /星期二|周二/,
            /星期三|周三/,
            /星期四|周四/,
            /星期五|周五/,
            /星期六|周六/,
            /星期日|星期天|周日|周天/
          ];

          matrix.forEach(function (row, rowIndex) {
            var rowText = row.map(function (cell) {
              return flatText(cell ? cell.innerText || cell.textContent : '');
            }).join(' ');

            if (headerRowIndex < 0 && /星期一|周一/.test(rowText) && /星期日|星期天|周日|周天/.test(rowText)) {
              headerRowIndex = rowIndex;
            }
          });

          if (headerRowIndex < 0) {
            return;
          }

          matrix[headerRowIndex].forEach(function (cell, colIndex) {
            var text = flatText(cell ? cell.innerText || cell.textContent : '');

            dayMatchers.forEach(function (matcher, dayIndex) {
              if (matcher.test(text) && dayColumns.indexOf(colIndex) < 0) {
                dayColumns[dayIndex] = colIndex;
              }
            });
          });

          var usedCells = [];
          var cellSerial = 0;

          for (var rowIndex = headerRowIndex + 1; rowIndex < matrix.length; rowIndex++) {
            var row = matrix[rowIndex] || [];
            var section = rowIndex - headerRowIndex;
            var sectionCell = row.find(function (cell) {
              var text = flatText(cell ? cell.innerText || cell.textContent : '');
              return /^\\d{1,2}$/.test(text);
            });

            if (sectionCell) {
              section = Math.max(1, Math.min(11, parseInt(flatText(sectionCell.innerText || sectionCell.textContent), 10)));
            }

            dayColumns.forEach(function (colIndex, dayIndex) {
              var cell = row[colIndex];

              if (cell && !cell.__codexCourseId) {
                cellSerial += 1;
                cell.__codexCourseId = cellSerial;
              }

              var cellKey = dayIndex + '-' + (cell ? cell.__codexCourseId : 'empty');

              if (!cell || usedCells.indexOf(cellKey) >= 0) {
                return;
              }

              var rawText = getRawCourseTextFromCell(cell);
              var blocks = getCourseBlocksFromCell(cell);

              if (blocks.length === 0 && isCourseCellText(rawText)) {
                blocks = splitCourseBlocksFromLines(rawText.split(/\\n+/));
              }

              if (blocks.length === 0 && isCourseCellText(rawText)) {
                blocks = [rawText];
              }

              blocks.forEach(function (block) {
                var clean = flatText(block);

                if (isUsefulCourseText(clean) && !isHeaderText(clean) && isCourseCellText(clean)) {
                  var sectionRange = parseSection(clean, section);
                  cells.push(clean);
                  courses.push({
                    day: dayIndex,
                    startSection: sectionRange.start,
                    endSection: sectionRange.end,
                    name: pickCourseNameFromCell(cell, block),
                    detail: pickDetail(block)
                  });
                }
              });

              usedCells.push(cellKey);
            });
          }
        }

        function collectCoursesFromTable(table) {
          var rows = safeQueryAll(table, 'tr');
          var headerIndex = rows.findIndex(function (row) {
            return /周一|星期一|周二|星期二|周日|星期日/.test(cleanText(row.innerText || row.textContent));
          });
          var startRow = headerIndex >= 0 ? headerIndex + 1 : 1;

          rows.slice(startRow).forEach(function (row, rowOffset) {
            var rowCells = getRowCells(row);

            if (rowCells.length === 0) {
              return;
            }

            var firstText = flatText(rowCells[0].innerText || rowCells[0].textContent);
            var sectionMatch = firstText.match(/(?:第)?\\s*(\\d{1,2})\\s*(?:节)?/);
            var fallbackSection = sectionMatch ? Math.max(1, Math.min(11, parseInt(sectionMatch[1], 10))) : Math.min(11, rowOffset + 1);
            var courseCells = rowCells.length >= 8 ? rowCells.slice(rowCells.length - 7) : rowCells.slice(1);

            courseCells.forEach(function (cell, day) {
              var blocks = getCourseBlocksFromCell(cell);

              blocks.forEach(function (block) {
                cells.push(flatText(block));
                addCourse(block, day, fallbackSection);
              });
            });
          });
        }

        collectCoursesFromTitleNodes();

        tables.forEach(function (table) {
          if (table.id === 'kbgrid_table_0') {
            collectCoursesFromGridTable(table);
          } else {
            collectCoursesFromTable(table);
          }
        });

        if (courses.length === 0) {
          safeQueryAll(document, '.kbcontent, .kbcontent1, [class*=kbcontent], [id*=kbcontent]').forEach(function (node, index) {
            var blocks = splitCourseBlocksFromLines(getElementLines(node));

            blocks.forEach(function (block, blockIndex) {
              cells.push(flatText(block));
              addCourse(block, (index + blockIndex) % 7, Math.min(11, Math.floor((index + blockIndex) / 7) + 1));
            });
          });
        }

        var courseKeys = {};
        courses = courses.filter(function (course) {
          var key = course.day + '-' + course.startSection + '-' + course.name;

          if (courseKeys[key]) {
            return false;
          }

          courseKeys[key] = true;
          return true;
        });

        return JSON.stringify({
          tableCount: tables.length,
          titleNodeCount: safeQueryAll(document, 'u.title.showJxbtkjl, u.showJxbtkjl, .showJxbtkjl[data-jxb_id], .showJxbtkjl[data-jxb-id], [data-jxb_id].title, [data-jxb-id].title').length,
          courseCellCount: cells.length,
          samples: cells.length > 0 ? cells.slice(0, 8) : safeQueryAll(document, '#kbgrid_table_0 td').map(function (cell) {
            return flatText(cell.innerText || cell.textContent || '').slice(0, 180);
          }).filter(function (text) {
            return text.length > 8 && !isHeaderText(text);
          }).slice(0, 8),
          courses: courses
        });
        } catch (scanError) {
          return JSON.stringify({
            tableCount: document && document.querySelectorAll ? document.querySelectorAll('table').length : 0,
            titleNodeCount: document && document.querySelectorAll ? document.querySelectorAll('u.title.showJxbtkjl, u.showJxbtkjl, .showJxbtkjl[data-jxb_id], .showJxbtkjl[data-jxb-id], [data-jxb_id].title, [data-jxb-id].title').length : 0,
            courseCellCount: 0,
            parseError: scanError && scanError.message ? scanError.message : String(scanError),
            samples: [],
            courses: []
          });
        }
      })();
    `;

    this.parseStatus = '正在扫描正方课表页面...';
    this.parsePreview = '';
    this.webController.runJavaScript(zhengfangScanner, (error, result) => {
      if (error) {
        this.parseStatus = '解析失败：请确认当前网页已经打开课表页面。';
        this.parsePreview = JSON.stringify(error);
        return;
      }

      let parsed: ZhengfangParseResult = {
        tableCount: 0,
        courseCellCount: 0,
        samples: []
      };

      try {
        const firstParsed = JSON.parse(result) as ZhengfangParseResult | string | null;

        if (firstParsed === null) {
          this.parseStatus = '解析失败：网页脚本返回为空，但应用不会再退出。';
          this.parsePreview = result ? result : '返回为空，可能是页面脚本执行异常。';
          return;
        }

        if (typeof firstParsed === 'string') {
          parsed = JSON.parse(firstParsed) as ZhengfangParseResult;
        } else {
          parsed = firstParsed;
        }
      } catch (parseError) {
        this.parseStatus = '解析失败：网页返回内容格式异常，但应用不会再退出。';
        this.parsePreview = result;
        return;
      }

      const tableCount: number = parsed.tableCount ? parsed.tableCount : 0;
      const titleNodeCount: number = parsed.titleNodeCount ? parsed.titleNodeCount : 0;
      const courseCellCount: number = parsed.courseCellCount ? parsed.courseCellCount : 0;
      const samples: string[] = Array.isArray(parsed.samples) ? parsed.samples : [];
      const courses: ImportedCourse[] = Array.isArray(parsed.courses) ? parsed.courses : [];

      if (parsed.parseError && parsed.parseError.length > 0) {
        this.parseStatus = `解析脚本出错。已扫描 ${tableCount} 个表格、${titleNodeCount} 个标题节点。`;
        this.parsePreview = parsed.parseError;
        return;
      }

      if (courseCellCount === 0 || courses.length === 0) {
        this.parseStatus = `未识别到课程。已扫描 ${tableCount} 个表格、${titleNodeCount} 个标题节点。`;
        this.parsePreview = samples.length > 0 ? samples.join('\n\n') : '提示：请确认已进入正方“学生课表查询”的课表结果页。';
        return;
      }

      if (courses.length === 1 && samples.length > 1) {
        this.parseStatus = '只解析到 1 门课程，已暂停导入。下面是抓到的页面片段，请据此调整规则。';
        this.parsePreview = samples.join('\n\n');
        return;
      }

      this.saveImportedCourses(JSON.stringify(courses), () => {
        this.parseStatus = `已导入 ${courses.length} 门课程，已保存到本地，正在返回课表。`;
        this.parsePreview = samples.length > 0 ? samples.join('\n\n') : '课程已写入本地课表。';
        router.back();
      });
    });
  }

  private diagnoseSchedulePage(): void {
    // 调试入口：输出网页表格、课程块和匹配结果，方便适配不同学校的正方页面。
    const diagnoseScript: string = `
      (function () {
        try {
        function toArray(list) {
          return list ? Array.prototype.slice.call(list) : [];
        }

        function cleanText(text) {
          return (text || '').replace(/\\u00a0/g, ' ').replace(/\\r/g, '\\n').replace(/[ \\t]+/g, ' ').replace(/\\n\\s+/g, '\\n').trim();
        }

        function flatText(text) {
          return cleanText(text).replace(/\\n+/g, ' ');
        }

        function getCells(row) {
          return toArray(row && (row.cells || row.children)).filter(function (cell) {
            return /td|th/i.test(cell.tagName || '');
          });
        }

        function dayOf(text) {
          var value = flatText(text);
          var days = [
            ['星期一', '周一', '星期1'],
            ['星期二', '周二', '星期2'],
            ['星期三', '周三', '星期3'],
            ['星期四', '周四', '星期4'],
            ['星期五', '周五', '星期5'],
            ['星期六', '周六', '星期6'],
            ['星期日', '星期天', '周日', '周天', '星期7']
          ];

          for (var i = 0; i < days.length; i++) {
            for (var j = 0; j < days[i].length; j++) {
              if (value.indexOf(days[i][j]) >= 0) {
                return i;
              }
            }
          }

          return -1;
        }

        function dayLabelOf(text) {
          var match = flatText(text).match(/星期[一二三四五六日天]|周[一二三四五六日天]/);
          return match ? match[0] : '';
        }

        function parseSection(text) {
          var value = flatText(text);
          var range = value.match(/(?:第)?\\s*(\\d{1,2})\\s*[-至~－—]\\s*(\\d{1,2})\\s*节/);
          if (!range) {
            range = value.match(/(?:^|\\s|星期[一二三四五六日天]\\s*|周[一二三四五六日天]\\s*)(\\d{1,2})\\s*[-至~－—]\\s*(\\d{1,2})(?!\\s*周)(?=\\s|[\\u4e00-\\u9fa5]|[★☆■]|$)/);
          }
          if (range) {
            return {
              start: parseInt(range[1], 10),
              end: parseInt(range[2], 10),
              raw: range[0]
            };
          }

          var single = value.match(/(?:第)?\\s*(\\d{1,2})\\s*节/);
          if (single) {
            var section = parseInt(single[1], 10);
            return {
              start: section,
              end: section,
              raw: single[0]
            };
          }

          return null;
        }

        function isHeaderText(text) {
          var value = flatText(text);
          if (!value) {
            return true;
          }
          if (/[★☆■]/.test(value) || /周数\s*[:：]|上课地点\s*[:：]|教师\s*[:：]/.test(value)) {
            return false;
          }
          return /^(星期|周|节次|课表信息|课程信息|上课地点|教师|时间段|时间|上午|下午|晚上)$/.test(value) ||
            (/学年|查询|打印|导出|课表查询|课程名称|教学班|红色斜体/.test(value) &&
              !/\d{1,2}\s*[-至~－—]\s*\d{1,2}(?!\s*周)/.test(value));
        }

        function isPossibleCourseText(text) {
          var value = flatText(text);
          return /[★☆■]/.test(value) ||
            /\\(\\s*\\d{1,2}\\s*[-至~－—]\\s*\\d{1,2}\\s*节\\s*\\)/.test(value) ||
            /(?:^|\\s)\\d{1,2}\\s*[-至~－—]\\s*\\d{1,2}(?!\\s*周)(?=\\s|[\\u4e00-\\u9fa5]|[★☆■])/.test(value) ||
            /\\d{1,2}\\s*[-至~－—]\\s*\\d{1,2}\\s*周/.test(value);
        }

        function splitSameSlotCourses(text) {
          var value = flatText(text);
          var starts = [];
          var markPattern = /[★☆■](?=\\s*(?:周数\\s*[:：]|\\(|\\d{1,2}\\s*[-至~－—]\\s*\\d{1,2}\\s*周|校区|上课地点|$))/g;
          var match = markPattern.exec(value);

          while (match) {
            var titleStart = value.lastIndexOf(' ', match.index);
            starts.push(titleStart >= 0 ? titleStart + 1 : 0);
            match = markPattern.exec(value);
          }

          var parts = [];
          for (var index = 0; index < starts.length; index++) {
            var start = starts[index];
            var end = index + 1 < starts.length ? starts[index + 1] : value.length;
            parts.push(value.slice(start, end));
          }

          return parts.length > 0 ? parts : [value];
        }

        function removeDayAndSectionText(text) {
          return flatText(text)
            .replace(/星期[一二三四五六日天]|周[一二三四五六日天]/g, ' ')
            .replace(/(?:第)?\\s*\\d{1,2}\\s*[-至~－—]\\s*\\d{1,2}(?!\\s*周)(?=\\s|[\\u4e00-\\u9fa5]|[★☆■]|$)\\s*节?/g, ' ')
            .replace(/(?:第)?\\s*\\d{1,2}\\s*节/g, ' ')
            .trim();
        }

        function pickRowParts(texts, rowText) {
          var dayText = '';
          var sectionText = '';
          var dayCellIndex = -1;
          var sectionCellIndex = -1;
          var sectionRange = null;

          texts.forEach(function (text, index) {
            if (dayCellIndex < 0 && dayOf(text) >= 0 && flatText(text).length <= 15) {
              dayCellIndex = index;
              dayText = dayLabelOf(text);
            }
          });

          texts.forEach(function (text, index) {
            var currentSection = parseSection(text);
            if (!currentSection) {
              return;
            }

            var previousSectionText = sectionCellIndex >= 0 && texts[sectionCellIndex] ? texts[sectionCellIndex] : '';
            var shouldUse = sectionCellIndex < 0 ||
              index === dayCellIndex ||
              index === dayCellIndex + 1 ||
              flatText(text).length < flatText(previousSectionText).length;

            if (shouldUse) {
              sectionCellIndex = index;
              sectionRange = currentSection;
            }
          });

          if (!dayText && dayOf(rowText) >= 0) {
            dayText = dayLabelOf(rowText);
          }

          if (sectionRange) {
            sectionText = sectionRange.start + '-' + sectionRange.end;
          } else {
            var rowSection = parseSection(rowText);
            if (rowSection) {
              sectionText = rowSection.start + '-' + rowSection.end;
            }
          }

          var courseParts = [];
          texts.forEach(function (text, index) {
            var candidate = text;
            if (index === dayCellIndex || index === sectionCellIndex) {
              candidate = removeDayAndSectionText(candidate);
            }

            if (!candidate || isHeaderText(candidate)) {
              return;
            }

            if (isPossibleCourseText(candidate) || (index !== dayCellIndex && index !== sectionCellIndex)) {
              courseParts.push(candidate);
            }
          });

          return {
            dayText: dayText,
            sectionText: sectionText,
            dayCellIndex: dayCellIndex,
            sectionCellIndex: sectionCellIndex,
            courseText: courseParts.join('\\n')
          };
        }

        function previewCourse(block, dayText, sectionText) {
          var raw = flatText(block);
          var section = parseSection(sectionText + ' ' + raw);
          var nameMatch = raw.match(/^(.+?)[★☆■]/);
          var weeksMatch = raw.match(/周数\\s*[:：]\\s*([0-9,，\\s至\\-－单双周]+)/) ||
            raw.match(/\\d{1,2}(?:\\s*[-至~－—]\\s*\\d{1,2})?(?:\\s*[,，]\\s*\\d{1,2}(?:\\s*[-至~－—]\\s*\\d{1,2})?)*\\s*(?:单|双)?周/);
          var typeMatch = raw.match(/[★☆■]/);

          return {
            dayText: dayText,
            dayIndex: dayOf(dayText + ' ' + raw),
            section: section ? section.start + '-' + section.end : '',
            sectionRaw: section ? section.raw : '',
            name: nameMatch ? removeDayAndSectionText(nameMatch[1]).replace(/[★☆■].*$/, '').trim() : '',
            weeks: weeksMatch ? (weeksMatch[1] ? weeksMatch[1] : weeksMatch[0]).replace(/\\s+/g, '') : '',
            type: typeMatch ? typeMatch[0] : '',
            block: raw.slice(0, 800)
          };
        }

        function previewListTable(table) {
          if (!table) {
            return null;
          }

          var lastDayText = '';
          var lastSectionText = '';
          var rows = toArray(table.querySelectorAll('tr')).map(function (row, rowIndex) {
            var cells = getCells(row);
            var texts = cells.map(function (cell) {
              return cleanText(cell.innerText || cell.textContent || '');
            }).filter(function (text) {
              return flatText(text).length > 0;
            });
            var rowText = cleanText(row.innerText || row.textContent || texts.join('\\n'));
            var rowParts = pickRowParts(texts, rowText);
            var dayText = rowParts.dayText;
            var sectionText = rowParts.sectionText;
            var courseText = rowParts.courseText;

            if (!dayText && dayOf(rowText) >= 0) {
              dayText = dayLabelOf(rowText);
            }

            if (!sectionText && (dayText || texts.length <= 1)) {
              var sectionFromRow = parseSection(rowText);
              if (sectionFromRow) {
                sectionText = sectionFromRow.start + '-' + sectionFromRow.end;
              }
            }

            var sectionFromCourse = parseSection(courseText);
            if (sectionFromCourse) {
              sectionText = sectionFromCourse.start + '-' + sectionFromCourse.end;
            }

            var inheritedDay = false;
            var inheritedSection = false;
            if (dayText) {
              lastDayText = dayText;
            } else {
              dayText = lastDayText;
              inheritedDay = true;
            }

            if (sectionText) {
              lastSectionText = sectionText;
            } else {
              sectionText = lastSectionText;
              inheritedSection = true;
            }

            if (!courseText || !isPossibleCourseText(courseText)) {
              courseText = rowText;
            }

            var blocks = isPossibleCourseText(courseText) ? splitSameSlotCourses(courseText) : [];

            return {
              rowIndex: rowIndex,
              cellCount: cells.length,
              texts: texts,
              rowText: rowText.slice(0, 1200),
              detected: {
                dayText: dayText,
                sectionText: sectionText,
                inheritedDay: inheritedDay,
                inheritedSection: inheritedSection,
                dayCellIndex: rowParts.dayCellIndex,
                sectionCellIndex: rowParts.sectionCellIndex
              },
              courseText: flatText(courseText).slice(0, 1200),
              blocks: blocks.map(function (block) {
                return previewCourse(block, dayText, sectionText);
              }),
              cells: cells.map(function (cell, cellIndex) {
                return {
                  cellIndex: cellIndex,
                  tag: cell.tagName,
                  className: cell.className || '',
                  rowSpan: cell.getAttribute('rowspan') || '',
                  colSpan: cell.getAttribute('colspan') || '',
                  text: cleanText(cell.innerText || cell.textContent || '').slice(0, 1200),
                  html: (cell.innerHTML || '').slice(0, 1200)
                };
              })
            };
          });

          return {
            id: table.id || '',
            className: table.className || '',
            rowCount: rows.length,
            courseRowCount: rows.filter(function (row) {
              return row && row.blocks && row.blocks.length > 0;
            }).length,
            rowsWithCourses: rows.filter(function (row) {
              return row && row.blocks && row.blocks.length > 0;
            }).slice(0, 40).map(function (row) {
              return {
                rowIndex: row.rowIndex,
                cellCount: row.cellCount,
                detected: row.detected,
                courseText: row.courseText,
                blocks: row.blocks
              };
            }),
            focusRows: rows.filter(function (row) {
              return /计算机组成|组成原理|线性代数|数据库概论|嵌入式系统/.test(row.rowText);
            }).slice(0, 20)
          };
        }

        function previewGridTable(table) {
          if (!table) {
            return null;
          }

          var rows = toArray(table.querySelectorAll('tr'));
          var headerIndex = -1;
          var dayLabels = ['星期一', '星期二', '星期三', '星期四', '星期五', '星期六', '星期日'];

          rows.forEach(function (row, index) {
            var text = flatText(row.innerText || row.textContent || '');
            if (headerIndex < 0 && /星期一|周一/.test(text) && /星期日|星期天|周日|周天/.test(text)) {
              headerIndex = index;
            }
          });

          var courseCells = [];
          if (headerIndex >= 0) {
            rows.slice(headerIndex + 1).forEach(function (row, rowOffset) {
              var cells = getCells(row);
              if (cells.length < 7) {
                return;
              }

              var sectionText = '';
              cells.some(function (cell) {
                var text = flatText(cell.innerText || cell.textContent || '');
                if (/^\\d{1,2}$/.test(text)) {
                  var section = parseInt(text, 10);
                  if (section >= 1 && section <= 11) {
                    sectionText = section + '-' + section;
                    return true;
                  }
                }
                return false;
              });

              if (!sectionText) {
                var fallbackSection = Math.min(11, rowOffset + 1);
                sectionText = fallbackSection + '-' + fallbackSection;
              }

              cells.slice(Math.max(0, cells.length - 7)).forEach(function (cell, dayIndex) {
                var rawText = cleanText(cell.innerText || cell.textContent || '');
                if (!isPossibleCourseText(rawText) || isHeaderText(rawText)) {
                  return;
                }

                var blockNodes = toArray(cell.querySelectorAll ? cell.querySelectorAll('.kbcontent, .kbcontent1, [class*=kbcontent], [id*=kbcontent]') : []);
                var blocks = [];
                blockNodes.forEach(function (node) {
                  var blockText = cleanText(node.innerText || node.textContent || '');
                  if (isPossibleCourseText(blockText) && !isHeaderText(blockText)) {
                    blocks.push(blockText);
                  }
                });

                if (blocks.length === 0) {
                  blocks = splitSameSlotCourses(rawText);
                }

                courseCells.push({
                  rowIndex: headerIndex + 1 + rowOffset,
                  dayIndex: dayIndex,
                  dayText: dayLabels[dayIndex],
                  rowSectionText: sectionText,
                  rawText: rawText.slice(0, 1200),
                  html: (cell.innerHTML || '').slice(0, 1200),
                  blocks: blocks.map(function (block) {
                    var blockSection = parseSection(block);
                    return previewCourse(block, dayLabels[dayIndex], blockSection ? block : sectionText);
                  })
                });
              });
            });
          }

          return {
            id: table.id || '',
            className: table.className || '',
            headerIndex: headerIndex,
            rowCount: rows.length,
            courseCellCount: courseCells.length,
            courseCells: courseCells.slice(0, 80).map(function (cell) {
              return {
                rowIndex: cell.rowIndex,
                dayIndex: cell.dayIndex,
                dayText: cell.dayText,
                rowSectionText: cell.rowSectionText,
                rawText: cell.rawText,
                blocks: cell.blocks
              };
            }),
            focusCells: courseCells.filter(function (cell) {
              return /计算机组成|组成原理|线性代数|数据库概论|嵌入式系统/.test(cell.rawText);
            }).slice(0, 20)
          };
        }

        var tables = toArray(document.querySelectorAll('table')).map(function (table, tableIndex) {
          var rows = toArray(table.querySelectorAll('tr'));
          var text = flatText(table.innerText || table.textContent || '');
          var score = rows.filter(function (row) {
            return toArray(row.children).length >= 8;
          }).length * 10 +
            (/星期一|周一/.test(text) ? 5 : 0) +
            (/星期日|周日/.test(text) ? 5 : 0);

          return {
            tableIndex: tableIndex,
            id: table.id || '',
            className: table.className || '',
            score: score,
            rowCount: rows.length,
            textSample: text.slice(0, 800)
          };
        }).sort(function (a, b) {
          return b.score - a.score;
        });
        var titleNodes = toArray(document.querySelectorAll('u.title, .showJxbtkjl, [data-jxb_id], [data-jxb-id], [data-kch], [data-kcmc], [data-kcm], font[title], span[title]'))
          .slice(0, 30)
          .map(function (node, index) {
            return {
              index: index,
              tag: node.tagName,
              className: node.className || '',
              text: flatText(node.innerText || node.textContent || node.getAttribute('title') || '').slice(0, 240),
              html: (node.outerHTML || '').slice(0, 420)
            };
          });

        var report = {
          url: location.href,
          title: document.title || '',
          note: '为了避免 WebView 返回 null，这里默认限制了 rowsWithCourses/courseCells 数量；请优先复制 focusRows 和 focusCells。',
          detectedTables: {
            hasListTable: !!document.querySelector('#kblist_table'),
            hasGridTable: !!document.querySelector('#kbgrid_table_0')
          },
          tableCount: tables.length,
          titleNodeCount: titleNodes.length,
          topTables: tables.slice(0, 8),
          listParserPreview: previewListTable(document.querySelector('#kblist_table')),
          gridParserPreview: previewGridTable(document.querySelector('#kbgrid_table_0')),
          titleNodes: titleNodes
        };
        var reportText = JSON.stringify(report, null, 2);
        if (reportText.length > 65000) {
          return reportText.slice(0, 65000) + '\\n\\n...内容过长，已截断。请优先复制 focusRows / focusCells 部分。';
        }
        return reportText;
        } catch (diagnoseError) {
          return '解析预览脚本异常：' + (diagnoseError && diagnoseError.message ? diagnoseError.message : String(diagnoseError));
        }
      })();
    `;

    this.parseStatus = '正在生成解析预览和网页详细信息...';
    this.parsePreview = '';
    this.webController.runJavaScript(diagnoseScript, (error, result) => {
      if (error) {
        this.parseStatus = '解析预览生成失败。';
        this.parsePreview = JSON.stringify(error);
        return;
      }

      this.parseStatus = '解析预览完成。请滑动查看，重点复制 focusRows / focusCells 部分给我。';
      if (result === null || result === undefined || result === 'null') {
        this.parsePreview = '解析预览返回为空。可能是当前页面脚本执行被 WebView 拦截，或返回内容仍然过大。请先确认页面已经停留在课表结果页，再点一次“解析预览”。';
        return;
      }

      let previewText: string = result;
      try {
        const decoded = JSON.parse(result) as string;
        if (typeof decoded === 'string') {
          previewText = decoded;
        }
      } catch (parseError) {
        previewText = result;
      }
      this.parsePreview = previewText;
    });
  }

  build() {
    Column() {
      Row({ space: 10 }) {
        Button('<')
          .width(40)
          .height(38)
          .fontSize(16)
          .fontColor('#2563EB')
          .backgroundColor('#DBEAFE')
          .borderRadius(19)
          .onClick(() => {
            router.back();
          })

        TextInput({ text: this.urlInput, placeholder: '输入教务网站地址' })
          .height(38)
          .layoutWeight(1)
          .fontSize(14)
          .backgroundColor('#F8FAFC')
          .borderRadius(12)
          .padding({ left: 12, right: 12 })
          .onChange((value: string) => {
            this.urlInput = value;
          })

        Button('进入')
          .width(64)
          .height(38)
          .fontSize(14)
          .fontColor('#FFFFFF')
          .backgroundColor('#2563EB')
          .borderRadius(12)
          .onClick(() => {
            this.openUrl();
          })
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 10, bottom: 10 })
      .backgroundColor('#FFFFFF')

      Web({ src: this.targetUrl, controller: this.webController })
        .width('100%')
        .layoutWeight(1)
        .javaScriptAccess(true)
        .domStorageAccess(true)
        .userAgent(this.pcUserAgent)

      Column({ space: 8 }) {
        Text(this.parseStatus)
          .width('100%')
          .fontSize(12)
          .fontColor('#64748B')
          .textAlign(TextAlign.Center)

        if (this.parsePreview.length > 0) {
          Scroll() {
            Text(this.parsePreview)
              .width('100%')
              .fontSize(11)
              .fontColor('#475569')
              .padding(10)
          }
          .width('100%')
          .height(220)
          .scrollable(ScrollDirection.Vertical)
          .backgroundColor('#F8FAFC')
          .borderRadius(10)
        }

        Row({ space: 10 }) {
          Button('解析预览')
            .layoutWeight(1)
            .height(48)
            .fontSize(16)
            .fontColor('#2563EB')
            .backgroundColor('#DBEAFE')
            .borderRadius(14)
            .onClick(() => {
              this.diagnoseSchedulePage();
            })

          Button('解析课表')
            .layoutWeight(1)
            .height(48)
            .fontSize(16)
            .fontColor('#FFFFFF')
            .backgroundColor('#2563EB')
            .borderRadius(14)
            .onClick(() => {
              this.parseListSchedule();
            })
        }
        .width('100%')
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 10, bottom: 16 })
      .backgroundColor('#FFFFFF')
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F8FAFC')
  }
}
