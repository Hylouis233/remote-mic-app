# 安装迁移测试误向正在使用的应用发送SIGTERM

## 确认的调用链

用户报告本机录音再次失效，build25日志记录22:57:18收到SIGTERM并正常执行APP STOP。
同轮完整Swift回归在22:58:01结束。静态审查确认：

- BuildSigningTests.releaseBundleNameMatchesBrandingAndInstallerPaths执行test-legacy-app-trash-migration.sh。
- 该fixture虽使用临时卷，却直接source生产trash-legacy-app.zsh。
- 生产函数在满足虚拟旧App所有权后执行绝对路径 `/usr/bin/pkill -x RemoteMic`；临时卷不隔离进程名。
- test-driver-naming.sh另两处复制同一helper，也会绕过已有的preinstall/postinstall命令桩。

真实、可达的SIGTERM路径及时间关联已确认；系统日志没有给出该秒的发送者PID，保留这一归因边界。
这不是证实的音频引擎崩溃，登录自启也不隔离测试中的进程副作用。

## 修复

fixture只加载拦截进程停止操作的helper副本，记录停止意图；生产安装语义不变。
命名矩阵的两处helper副本同样改为测试桩。没有新增可覆盖root安装命令的运行环境变量。
迁移回归加入自己编译的同名RemoteMic测试进程，所有迁移场景结束后它必须仍然存活；
同时验证停止意图确已经过桩，防止只跳过业务分支而假通过。

## 验证

独立迁移fixture通过，同名测试进程存活，日常使用的实际SayAll进程在执行前后保持同一实例。
测试命名脚本语法通过；完整Swift回归及命名矩阵结果单独记录，不以语法检查替代行为验证。
后续固化由登录项、G9唤醒恢复、测试副作用隔离和进程存活回归共同覆盖；不宣称程序永不发生其他故障。
