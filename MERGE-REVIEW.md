# 蓝牙增强5.8.8.1：冻结基线合并审查

## 来源

用户明确要求继续合并、尽量审查与精简；冷启动修复和混音实验暂停。两个输入ZIP仍原样保存在merge-baselines.zip中：

- 原网易云/弹窗改名版：99文件，SHA256 f7cf520654de5d7ce78274d38fa056c30d175a9784686beaaa60469a75940ec5。
- 当前酷我独立音频状态版：46文件，SHA256 1f1d2dad2380cbfdaaa57ea15a75771c04ab672d4826d56c1b99b7b64c9e5334。

酷我“已有后台时可播”为用户反馈，不扩大到冷启动、注销或用户空间重启后首次。合并后行为尚待设备验证。

## 实际合并与精简

1. 网易云所有运行实现、弹窗与设置实现、共享Gate/Config/Preferences按旧基线保留；未带入后来Cloud控制加固。CloudRuntime.h只删除一条无实现/无引用的inventory声明，不删除导出函数实现。
2. 酷我15文件从冻结独立包反向命名映射接入共享Gate；KuwoRuntime.h只清除同类无用inventory声明。KuwoLog提示与KuwoProcess快照文件名适配原HeadsetBridge日志约定。Playback/Music/Background/SB/FlowTrace/AudioStatus算法按冻结来源保持，没有新冷启动、混音或授权变更。
3. 酷我专属AudioStatus→FlowTrace→Diagnostics安装顺序保留，三个相同bundle判断合成一处。网易云不安装酷我Hook。Card独立dylib仍只SB/SharingViewService，SB仅配置中转。
4. Makefile与清单仅增加音频观测源及AudioToolbox，保持独立.m编译单元。删除无引用空私有头和两个无用搜索路径；未将含同名静态变量的模块粗暴拼接到.xm。
5. 工作目录移出40份重复历史脚本/报告/JSON证据，但完整原件仍在来源ZIP中，原全部回归从临时目录执行。不是删除测试后忽略失败，也没有更新原基线散列掩盖差异。连同空头，共41个旧文件离开当前构建树。
6. 包标识com.alex.bluetoothenhance、显示名蓝牙增强、作者Alex、版本5.8.8.1、详情及CI固定版本保持。Conflicts增加com.alex.kuwoprobe，防止独立包与合并包同时参与酷我。旧com.axs.headsetbridge替换关系保留。

这些精简主要整理源码组织与验收材料，未宣称显著降低二进制体积或消除日志运行开销。保留已有诊断安装和原取消检查，避免把一次新的性能实验混入合并。

## 只读复核

- 配置/租约复核：未发现本次合并新增的重复Play、跨引擎授权或独立prefs误迁移。配置切换先撤销两个binding，lease/epoch/前后快照和最终路由检查保留；旧请求在目标切回后也不能只凭相同target复活。
- 构建/链接复核：未发现AudioStatus接入新增的确定性声明/链接接线错误。新增接口有extern C；AudioQueue保留SDK签名赋值检查；库清单AudioToolbox/substrate完整；音乐18源、卡片4源、偏好3实现，各编译一次。
- 复核发现的日志路径不一致、精简导致旧验证器依赖缺失均已处理：路径改动单独登记，当前build只调用validate_merge.py，旧脚本从不可变输入ZIP恢复后运行。独立审查不是Apple SDK编译结论。

## 最终验收

- validate_merge.py完整通过：来源ZIP SHA、固定获准差异清单摘要、15文件映射及路径/声明例外精确检查、双目标filter、编译清单/头引用、原配置与单次Play限制，以及两份原项目的全部原验收。
- 32个选择/epoch有效能力案例与44个消费前后取消/重复投递设计场景通过。
- test_merge.py实际执行固定版本CI shell，模拟根theos-roothide与SDK目录后完整校验通过；11项未经批准的源码/元数据/新增文件变更仍拒绝。
- 两份原始归档SHA未变。

没有完整Theos/clang/Apple SDK，未实际编译链接/生成deb/运行GitHub或Mac/安装验包/真机测试。本版只交付源码合并候选。跨进程check-call仍非原子；系统调度、沙盒、Substrate实际覆盖、音频输出及配置迁移需真机。已知!int/锁屏首次失败及亮屏现象不在本次修复范围。

使用与回退按README：保存独立deb，移除独立包后正常安装合并包，合并设置中明确选择酷我并开启，真实重连；先有后台酷我一次，再网易云和常用弹窗各一次，失败保留当轮日志。
