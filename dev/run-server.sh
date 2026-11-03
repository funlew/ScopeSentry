#!/bin/sh
# air 编译完成后由它拉起进程。
# 必须 cd 到 /data：服务端用相对路径写 PLUGINKEY，而 config.yaml / PASSWORD /
# files / uploads / images 都以可执行文件所在目录为根。
set -eu
cd /data
exec /data/ScopeSentry
