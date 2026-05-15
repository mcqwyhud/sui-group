# SUI Group

## 访问地址

后端管理系统: http://127.0.0.1:8081/vue

前端门户(需要启用): http://127.0.0.1:8080

## 安装脚本

### sui-agent 安装
```bash
bash <(curl -Ls https://raw.githubusercontent.com/mcqwyhud/sui-group/main/agent_linux_install_v1.0.sh)
```

### sui-external 安装
```bash
bash <(curl -Ls https://raw.githubusercontent.com/mcqwyhud/sui-group/main/external_linux_install_v1.0.sh)
```

### sui-master 安装
```bash
bash <(curl -Ls https://raw.githubusercontent.com/mcqwyhud/sui-group/main/master_linux_install_v1.0.sh)
```

### 下载到指定目录 
```bash
sudo wget -O /opt/sui-external/config/static/portal/android_arm64.apk https://github.com/mcqwyhud/sui-group/releases/download/v1.0.0/android_arm64.apk
```

### 备份MySql一键安装

```bash
# 一行命令安装（全程交互式，Token 输入时不显示）
read -rsp "请输入 GitHub Token: " TOKEN && echo && bash <(curl -fsSL -H "Authorization: token $TOKEN"   -H "Accept: application/vnd.github.v3.raw"   "https://api.github.com/repos/mcqwyhud/sui-master/contents/db-backup/install.sh?ref=main")
```

### 安装nginx,默认80端口
服务器文件存放目录/opt/download
下载地址：
```bash
http://ip/文件全名
```
#### 无限速版安装
```bash
sudo apt update && sudo apt install nginx -y && sudo mkdir -p /opt/download && echo 'server { listen 80; server_name _; root /opt/download; location / { autoindex on; autoindex_exact_size off; autoindex_localtime on; if ($request_filename ~* ^.*?\.(apk|zip)$) { add_header Content-Disposition "attachment;"; } } }' | sudo tee /etc/nginx/sites-available/default && sudo systemctl restart nginx && echo -e "\n\033[32m【配置成功】Nginx 已就绪！下载目录已更改为: /opt/download\033[0m\n"
```
#### 限速版安装
```bash
sudo tee /etc/nginx/nginx.conf << 'EOF'
user www-data;
worker_processes auto;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;
events { worker_connections 768; }
http {
    sendfile on;
    tcp_nopush on;
    types_hash_max_size 2048;
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    ssl_protocols TLSv1 TLSv1.1 TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    access_log /var/log/nginx/access.log;
    error_log /var/log/nginx/error.log;
    gzip on;
    
    # 【1. 下载间隔】每分钟最多2次请求，即平均每 30 秒才能点击下载一次
    limit_req_zone $binary_remote_addr zone=download_limit:10m rate=2r/m;
}
EOF

sudo tee /etc/nginx/sites-available/default << 'EOF'
server {
    listen 80;
    server_name _;
    root /opt/download; # 指定你的 /opt/download 目录

    location / {
        autoindex on;
        autoindex_exact_size off;
        autoindex_localtime on;
        
        # 【2. 启用间隔与限速】
        limit_req zone=download_limit nodelay; # 30秒内重复点击直接拦截 (返回503错误)
        limit_rate 500k;                       # 限制每个用户的下载速度最大为 500 KB/s
        
        if ($request_filename ~* ^.*?\.(apk|zip)$) {
            add_header Content-Disposition "attachment;";
        }
    }
}
EOF

sudo systemctl restart nginx && echo -e "\n\033[32m【限速配置成功】已对 /opt/download 目录启用 500KB/s 限速与 30秒间隔！\033[0m\n"
```
