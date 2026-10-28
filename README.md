# 学创杯总经理页爬虫

本项目完全开源、免费，仅供学习使用。

登录自己的学创杯客户端，打开「总经理」窗口后，抓取当前登录这一家公司的总经理页面。每个人用自己的账号，脚本不会去抓其他队伍。

## 使用

1. 打开学创杯客户端并登录。
2. 进入总经理页面。这个窗口不要关，也不要缩成只剩任务栏。
3. 双击 `运行爬虫.bat`。
4. 结果在本目录的 `gm_公司编号` 文件夹里。正文是 `.txt`，原始页面是 `.html`，清单是 `manifest.json`。

把 `crawl_gm.ps1`、`运行爬虫.bat`、`使用说明.txt` 和本说明一起拷给别人即可。对方电脑上要已安装并登录这个客户端。

## 命令行

```powershell
powershell -STA -NoProfile -ExecutionPolicy Bypass -File .\crawl_gm.ps1
powershell -STA -NoProfile -ExecutionPolicy Bypass -File .\crawl_gm.ps1 -ListOnly
powershell -STA -NoProfile -ExecutionPolicy Bypass -File .\crawl_gm.ps1 -OutDir D:\输出目录
```

`-ListOnly` 只列出将要抓的页面，不写文件。不指定 `-OutDir` 时，结果写到脚本旁边的 `gm_公司编号`。

## 抓取范围

公司编号、学生编号和课程编号从当前总经理窗口的页面地址里读取。读不到这些编号时，脚本会停止，不会改用别的公司。

会保存当前窗口里看得见的栏目，包括菜单页面、页面上已有的图表、分季财务报表，以及管理驾驶舱仪表。公司资料、注册成绩、学生成绩管理、实验报告填写这些隐藏菜单不抓。地址相同、只是标题不同的菜单只保存一次。

## 文件

| 文件 | 作用 |
| --- | --- |
| `crawl_gm.ps1` | 爬虫脚本 |
| `运行爬虫.bat` | 双击运行 |
| `使用说明.txt` | 四步用法 |
| `.gitignore` | 不把抓取结果放进版本库 |

`总经理/`、`gm_*/`、`_raw/` 里的抓取结果只留在本机，不纳入版本库。
