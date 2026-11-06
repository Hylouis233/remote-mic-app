# 跨电脑语音输入候选验收

行为以 [产品规范](../feature/remote-voice/PRODUCT_SPEC.md) 和 [语音合同](HardwareVoiceAudioContract.md) 为准。
适用于一台 Windows Deskflow 服务端与本 Mac 客户端；多客户端拓扑未验，不据 Mac 非活动状态猜测其他电脑。

## 准备

1. 保持 G9N9N 与 Mac 配对及本机 SayAll 语音可用。无需改配对或关闭 Deskflow。
2. Windows 安装用户选择的语音输入工具，并通过其可见界面启用全局语音、设置按住语音快捷键。
3. Windows 已有用户选择的虚拟声卡；识别工具的麦克风选择该声卡的 capture/output 端点。
   接收器输出端必须是对应虚拟 render/input 端点，不能选择物理扬声器。
4. 使用现有 SSH 配置，确认目标身份和严格主机密钥验证可用；不在仓库填入私钥、主机地址或本机路径。
5. Windows 在当前交互用户下执行 `scripts/install-remote-voice-windows.ps1 -DeviceName '<虚拟输出名称>' -VoiceKey 113`。
   113 对应 F2，164 对应左Alt，必须与语音工具实际设置一致。该入口只管理自己的当前用户任务，不创建管理员服务或网络监听。
   已存在无窗口启动包装器时，验证其仅启动本组件，再保留动作/退出码传播并更新参数；不覆盖未知任务。
6. Mac 用户明确选择 Deskflow 公开日志文件，仅解析进入/离开屏幕/断线，不读取其他私有文件。
   将本功能自己的 `remoteVoice.sshHost`、`remoteVoice.focusLog` 设为所选 SSH 别名和文件，
   `remoteVoice.deskflowConfig`、`remoteVoice.expectedDeskflowServer` 绑定用户选择的配置与其中的服务端，最后开启 `remoteVoice.enabled`。
   服务端变化时必须重新选择目标，防止已验证的SSH目的地与当前键鼠电脑不同。
   默认关闭；关闭该键即恢复纯本机语音。设置后重启当前候选 App。

## 自动化与无输入预检

- `swift test --disable-keychain --jobs 4 --filter RemoteVoiceRouteTests`：焦点日志分片/轮转、源进程退出、超长行、分帧、目标锁定、generation隔离、背压、取消和本机透传；真实管道的小握手须在写端仍打开时返回，暂时无数据不得误判为EOF。
- Windows `-BuildOnly`：在有界 Staging 编译和自测，不替换运行版本。
- 接收器 `--self-test`：协议上限、二进制完整往返、释放失败保留所有权、后续恢复及闲置期限；不发按键或音频。
- `--audio-self-test --device '<虚拟输出名称>'`：32000个静音样本经过真实虚拟输出自然排空，不触发语音键。
- 安装后 `--diagnose-audio`：验证同用户管道及真实交互桌面输出，仍只使用静音，不触发语音键。
- SSH stdio使用Base64行包裹长度帧，验证控制字节不会被Windows shell换行或文本编码改写。
- `python3 Tests/RemoteVoiceTransportTests.py --host <所选SSH别名>` 验证不关闭输入即收到回显；
  `--audio-probe` 连续验证两轮真实虚拟声卡静音排空，仍不触发录音键。仅EOF后响应不算通过。

## 真实用户步骤

1. 鼠标留在 Mac，有光标的空白文本框中按住说第一句、松开，再说第二句。
   两次都应走原本机语音工具；Windows不得出现录音浮窗。
2. 将鼠标通过 Deskflow 移到 Windows，聚焦空白测试编辑器。按住遥控器说两句、分别松开。
   每次Windows工具均应启动/结束，文字进入Windows焦点编辑器；Mac不得启动本机听写。
3. 移回Mac再测一句，然后再次移到Windows测一句。每次按下按当时目标选路，一次会话中不改目标。
4. Windows说超过60秒的长段，确认首尾完整、没有中途停止；对照G9保活和两端样本/自然排空日志。
5. 连续快速开始第二句，确认旧PCM、尾部静音和旧结束回调不进入下一会话。
6. 在测试会话中断开SSH连接或关闭接收器，确认语音键释放、无卡住的按键或录音窗口；恢复后再试。
   源端接收不到目标就绪时应明确阻止远端会话，不把音频改发本机。
7. 退出接收器、重新运行安装入口，确认只停止/替换自己的组件，原Deskflow及其他任务保持运行。

## 失败判定及取证

未启动语音浮窗、文字进入错误电脑、丢首尾、持续按键、跨会话混入、背压/断线记为正常，均算失败。
收到PCM、SSH提交或MME播放完毕只证明各自阶段，不证明外部工具识别成功。
Mac复用AppLogger；Windows仅自己的LocalAppData/SayAllRemoteVoice/Logs，最多3份、每份2MiB、最长7天。
日志仅含阶段、样本数、延迟及原因类别，不取用户输入、原始音频、私有设置、设备标识或凭据。

## 当前候选结果

Mac基础焦点/协议和会话隔离测试已通过，最新完整公开1311项/95套件通过，包含登录、唤醒、会话隔离、EOF前小消息及背压路径。
Windows自测、保持producer打开的SSH往返、同连接连续两轮32000静音样本输出和交互桌面管道探测通过，未触发真实语音键。
接收器暂存升级、安全退出/重新启动及升级后交互桌面静音输出复验通过；任务以普通交互用户运行。
用户已安装Windows豆包并确认其配置为左Alt，麦克风已选对应虚拟capture端点；接收器匹配164，实际录音及文字上屏仍随真机测试确认。
Mac持续SSH小握手原先被Foundation读取缓冲阻塞，已用EOF前失败回归定位，修复及边界见
[Mac握手记录](../Bugs/2026-11-07-remote-voice-mac-handshake-buffering.md)。
用户已选择Deskflow配置与日志。现有配置的log/level字符串已按该版本公开格式规范为数值4，
客户端短暂重连后出现真实Mac→Windows→Mac焦点事件；未改变剪贴板、证书或输入内容设置。
Mac登录自动启动已通过原生设置开启；G9唤醒重连候选及其真实验证边界见
[恢复记录](../Bugs/2026-11-06-g9n9n-login-and-wake-recovery.md)。
真实Mac/Windows切换、豆包录音、文字上屏、长句及异常恢复尚待用户验收，不能据预检宣布跨机完成。

## 回退

关闭Mac自己的 `remoteVoice.enabled` 后重启SayAll，保留原本机语音路径。
Windows退出本组件后可执行安装入口 `-Uninstall`，仅移除自己的启动任务并将组件文件送入回收站。
不卸载用户的输入法或声卡；Windows卸载入口不改Deskflow设置、证书或其他辅助组件。
Mac此次焦点日志级别的单字段回退记录单独保留在本机，按需还原，不整份覆盖第三方配置。

## 更新定制分支

先同步fork主线，再在自己的功能分支合入最新 `upstream/main`；冲突按原功能语义处理，不用上游文件整份覆盖定制。
执行相关测试后沿原 `scripts/package-local-test-app.sh` 重打本地包，构建号递增、保留稳定签名和用户配置。
上游App发布版本、公开main源码和私有平台版本属于不同对象；公开构建合并私有版本清单，不代表取得私有实现。
本候选已合入截至本次检查的上游a29dad8（动作语义/说明和私有平台版本指针更新），未发现该批公开改动涉及G9音频收包路径。

迁移fixture原先会触发真实pkill，已改为命令桩；完整回归后日常SayAll进程保持同一实例，见[误停回归记录](../Bugs/2026-11-07-installer-fixture-terminates-running-app.md)。
