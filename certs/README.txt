把需要注入系统的原始 CA 证书放到这个目录（.crt / .cer / .der / .pem，DER 或 PEM 编码均可）。

  /data/adb/modules/auto_system_ca/certs/

流程：放入这里 → 模块页点「执行」（转换产物输出到 ../converted/，原文件保留）
→ 重启生效。设备有 openssl 时直接重启即可，开机自动转换。

转换来源映射：cat ../converted/mapping.txt（格式：hash.N|原始文件名）

注意事项：
- 支持扩展名：.crt .cer .der .pem
- 文件名不要包含空格或特殊字符
- 删除这里的证书文件并重启，对应转换文件与已注入证书会自动移除
- 如果 ROM 缺少 openssl，可把静态 openssl 放到模块的 tools/ 目录
  （/data/adb/modules/auto_system_ca/tools/openssl），或用 Termux 安装
  （pkg install openssl-tool）
