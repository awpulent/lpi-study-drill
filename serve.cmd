@echo off
rem Fallback launcher: serves the folder over localhost, then opens it.
rem Use this if your browser blocks storage on file:// URLs.
start "" http://127.0.0.1:8777/index.html
python -m http.server 8777 --bind 127.0.0.1 --directory "%~dp0"
