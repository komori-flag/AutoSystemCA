把需要注入系统的 CA 证书放到这个目录（.crt / .cer / .der / .pem，DER 或 PEM 编码均可）。

  /data/adb/modules/auto_system_ca/certs/

放好后重启手机，证书会被自动转换并安装进系统信任库。
进度日志：logcat | grep AutoSystemCA

注意事项：
- 支持扩展名：.crt .cer .der .pem
- 文件名不要包含空格或特殊字符
- 删除这里的证书文件并重启，对应证书会从系统信任库移除
- 如果 ROM 缺少 openssl，可把静态 openssl 放到模块的 tools/ 目录
  （/data/adb/modules/auto_system_ca/tools/openssl）
