#!/bin/bash
#数据挂载目录
volume=/data
#docker挂载目录
dockerDir=/var/lib/docker/
#所需监控节点IP
node1=172.16.98.188
node2=172.16.98.198
node3=172.16.99.22
#邮箱smtp服务器代理地址
smtp_smarthost="smtp.qq.com:465"
#发送邮箱名称
smtp_from="2430712627@qq.com"
#邮箱名称
smtp_auth_username="2430712627@qq.com"
#邮箱密码或授权码
smtp_auth_password="aicppknrfjaxdjdf"
#收件人邮箱,如需设置多个收件人 例："111@163.com,222@163.com"
email_to="2430712627@qq.com,15903451005@163.com"

function Load() {
docker load -i ./node.tar &> /dev/null && docker load -i ./prometheus.tar &> /dev/null && docker load -i ./alertmanager.tar &> /dev/null && docker load -i ./grafana.tar &> /dev/null
  if [ $? -eq 0 ];then
    echo "docker load successfully"
  else
    echo "docker load failed" && exit
  fi
  if [ ! -d "$volume/prom/data" ];then
    mkdir -p $volume/prom/data && chmod -R 777 $volume/prom/data
    if [ $? -ne 0 ];then
    echo "Permission denied" && exit
    fi
  fi
}

function Node() {
docker rm -f node-exporter &> /dev/null
docker run -d -p 9100:9100 --name node-exporter prom/node-exporter:latest &> /dev/null
  if [ $? -eq 0 ];then
    echo "node Startup successfully"
  else
    echo "node Startup failed" && exit
  fi
read -p "请在其他 $node1、$node2 节点启动 node-exporter，如已启动请输入 y/n：" code
case $code in
  y|yes)
    echo "其他节点 node-exporter 已确认启动"
    ;;
  *)
    echo "请确认其他节点node-exporter是否启动，如已启动请输入y"
    exit
esac
}

function Alertmanager() {
docker rm -f alertmanager &> /dev/null
docker run -d -p 9093:9093 -p 9094:9094 -v $volume/prom/alertmanager.yml:/etc/alertmanager/alertmanager.yml --name alertmanager prom/alertmanager:latest &> /dev/null
  if [ $? -eq 0 ];then
    echo "alertmanager Startup successfully"
  else
    echo "alertmanager Startup failed" && exit
  fi
}

function Cadvisor() {
docker rm -f cadvisor &> /dev/null
docker load -i cadvisor.tar &> /dev/null
docker run -d -v /:/rootfs:ro -v /var/run:/var/run:rw -v /sys:/sys:ro -v $dockerDir:/var/lib/docker:ro -v /dev/disk/:/dev/disk:ro -p 1111:8080  --name=cadvisor --restart=always google/cadvisor:latest &> /dev/null
  if [ $? -eq 0 ];then
    echo "Cadvisor Startup successfully"
  else
    echo "Cadvisor Startup failed" && exit
  fi
} 

function Prometheus() {
docker rm -f prometheus &> /dev/null
docker run -d -p 9090:9090 -v $volume/prom/prometheus.yml:/etc/prometheus/prometheus.yml -v $volume/prom/alert-rules.yml:/etc/prometheus/alert-rules.yml -v $volume/prom/data:/prometheus --name prometheus prom/prometheus:latest &> /dev/null
  if [ $? -eq 0 ];then
    echo "Prometheus Startup successfully"
  else
    echo "Prometheus Startup failed" && exit
  fi
}

function Grafana() {
docker rm -f grafana &> /dev/null
mkdir -p $volume/prom/grafana && chmod 777 $volume/prom/grafana
docker run -d -p 3000:3000 -v $volume/prom/grafana:/var/lib/grafana --name=grafana grafana/grafana:latest &> /dev/null
  if [ $? -eq 0 ];then
    echo "Grafana Startup successfully"
    echo "浏览器请访问 http://$node1:3000 ，默认账号密码：admin/admin，添加数据源后，添加8919模板即可"
  else
    echo "Grafana Startup failed" && exit
  fi
}

function Writealertprometheus() {
cat > $volume/prom/prometheus.yml << EOF
global:
  scrape_interval:     15s
  evaluation_interval: 15s

alerting:
  alertmanagers:
  - static_configs:
    - targets:
      - $node1:9093

rule_files:
  - "*rules.yml"
  
scrape_configs:
  - job_name: 'node'
    static_configs:
    - targets: ['$node1:9100','$node2:9100','$node3:9100']
  - job_name: 'Cadvisor'
    static_configs:
    - targets: ['$node1:1111']
EOF
}

function Writeprometheus() {
cat > $volume/prom/prometheus.yml << EOF
global:
  scrape_interval:     15s
  evaluation_interval: 15s

rule_files:
  - "*rules.yml"

scrape_configs:
  - job_name: 'node'
    static_configs:
    - targets: ['$node1:9100','$node2:9100','$node3:9100']
  - job_name: 'Cadvisor'
    static_configs:
    - targets: ['$node1:1111']
EOF
}

function Writealert() {
cat > $volume/prom/alertmanager.yml << END
global:
  resolve_timeout: 5m
  smtp_smarthost: '$smtp_smarthost'
  smtp_from: '$smtp_from'
  smtp_auth_username: '$smtp_auth_username'
  smtp_auth_password: '$smtp_auth_password'
  smtp_require_tls: false
  smtp_hello: 'qq.com'
route:
  receiver: 'default'
  group_wait: 10s
  group_interval: 1m
  repeat_interval: 1h
  group_by: ['alertname']

inhibit_rules:
- source_match:
    severity: 'critical'
  target_match:
    severity: 'warning'
  equal: ['alertname', 'instance']
  
receivers:
- name: 'default'
  email_configs:
  - to: '$email_to'
    send_resolved: true
END
}

function Writerules() {
cat > $volume/prom/alert-rules.yml << EDG
groups:
  - name: node-alert
    rules:
    - alert: NodeDown
      expr: up{job="node"} == 0
      for: 30s
      labels:
        severity: critical
        instance: "{{ \$labels.instance }}"
      annotations:
        summary: "instance: {{ \$labels.instance }} down"
        description: "Instance: {{ \$labels.instance }} 已经宕机 30秒"
        value: "{{ \$value }}"
        
    - alert: NodeCpuHigh
      expr: (1 - avg by (instance) (irate(node_cpu_seconds_total{job="node",mode="idle"}[5m]))) * 100 > 80
      for: 5m
      labels:
        severity: warning
        instance: "{{ \$labels.instance }}"
      annotations:
        summary: "instance: {{ \$labels.instance }} cpu使用率过高"
        description: "CPU 使用率超过 80%"
        value: "{{ \$value }}"

    - alert: NodeCpuIowaitHigh
      expr: avg by (instance) (irate(node_cpu_seconds_total{job="node",mode="iowait"}[5m])) * 100 > 50
      for: 5m
      labels:
        severity: warning
        instance: "{{ \$labels.instance }}"
      annotations:
        summary: "instance: {{ \$labels.instance }} cpu iowait 使用率过高"
        description: "CPU iowait 使用率超过 50%"
        value: "{{ \$value }}"

    - alert: NodeLoad5High
      expr: node_load5 > (count by (instance) (node_cpu_seconds_total{job="node",mode='system'})) * 1.2
      for: 5m
      labels:
        severity: warning
        instance: "{{ \$labels.instance }}"
      annotations:
        summary: "instance: {{ \$labels.instance }} load(5m) 过高"
        description: "Load(5m) 过高，超出cpu核数 1.2倍"
        value: "{{ \$value }}"

    - alert: NodeMemoryHigh
      expr: (1 - node_memory_MemAvailable_bytes{job="node"} / node_memory_MemTotal_bytes{job="node"}) * 100 > 90
      for: 5m
      labels:
        severity: warning
        instance: "{{ \$labels.instance }}"
      annotations:
        summary: "instance: {{ \$labels.instance }} memory 使用率过高"
        description: "Memory 使用率超过 90%"
        value: "{{ \$value }}"

    - alert: NodeDiskRootHigh
      expr: (1 - node_filesystem_avail_bytes{job="node",fstype=~"ext.*|xfs",mountpoint ="/"} / node_filesystem_size_bytes{job="node",fstype=~"ext.*|xfs",mountpoint ="/"}) * 100 > 90
      for: 10m
      labels:
        severity: warning
        instance: "{{ \$labels.instance }}"
      annotations:
        summary: "instance: {{ \$labels.instance }} disk(/ 分区) 使用率过高"
        description: "Disk(/ 分区) 使用率超过 90%"
        value: "{{ \$value }}"

    - alert: NodeDiskBootHigh
      expr: (1 - node_filesystem_avail_bytes{job="node",fstype=~"ext.*|xfs",mountpoint ="/boot"} / node_filesystem_size_bytes{job="node",fstype=~"ext.*|xfs",mountpoint ="/boot"}) * 100 > 80
      for: 10m
      labels:
        severity: warning
        instance: "{{ \$labels.instance }}"
      annotations:
        summary: "instance: {{ \$labels.instance }} disk(/boot 分区) 使用率过高"
        description: "Disk(/boot 分区) 使用率超过 80%"
        value: "{{ \$value }}"

    - alert: NodeDiskReadHigh
      expr: irate(node_disk_read_bytes_total{job="node"}[5m]) > 20 * (1024 ^ 2)
      for: 5m
      labels:
        severity: warning
        instance: "{{ \$labels.instance }}"
      annotations:
        summary: "instance: {{ \$labels.instance }} disk 读取字节数 速率过高"
        description: "Disk 读取字节数 速率超过 20 MB/s"
        value: "{{ \$value }}"

    - alert: NodeDiskWriteHigh
      expr: irate(node_disk_written_bytes_total{job="node"}[5m]) > 20 * (1024 ^ 2)
      for: 5m
      labels:
        severity: warning
        instance: "{{ \$labels.instance }}"
      annotations:
        summary: "instance: {{ \$labels.instance }} disk 写入字节数 速率过高"
        description: "Disk 写入字节数 速率超过 20 MB/s"
        value: "{{ \$value }}"
        
    - alert: NodeDiskReadRateCountHigh
      expr: irate(node_disk_reads_completed_total{job="node"}[5m]) > 3000
      for: 5m
      labels:
        severity: warning
        instance: "{{ \$labels.instance }}"
      annotations:
        summary: "instance: {{ \$labels.instance }} disk iops 每秒读取速率过高"
        description: "Disk iops 每秒读取速率超过 3000 iops"
        value: "{{ \$value }}"

    - alert: NodeDiskWriteRateCountHigh
      expr: irate(node_disk_writes_completed_total{job="node"}[5m]) > 3000
      for: 5m
      labels:
        severity: warning
        instance: "{{ \$labels.instance }}"
      annotations:
        summary: "instance: {{ \$labels.instance }} disk iops 每秒写入速率过高"
        description: "Disk iops 每秒写入速率超过 3000 iops"
        value: "{{ \$value }}"

    - alert: NodeInodeRootUsedPercentHigh
      expr: (1 - node_filesystem_files_free{job="node",fstype=~"ext4|xfs",mountpoint="/"} / node_filesystem_files{job="node",fstype=~"ext4|xfs",mountpoint="/"}) * 100 > 80
      for: 10m
      labels:
        severity: warning
        instance: "{{ \$labels.instance }}"
      annotations:
        summary: "instance: {{ \$labels.instance }} disk(/ 分区) inode 使用率过高"
        description: "Disk (/ 分区) inode 使用率超过 80%"
        value: "{{ \$value }}"

    - alert: NodeInodeBootUsedPercentHigh
      expr: (1 - node_filesystem_files_free{job="node",fstype=~"ext4|xfs",mountpoint="/boot"} / node_filesystem_files{job="node",fstype=~"ext4|xfs",mountpoint="/boot"}) * 100 > 80
      for: 10m
      labels:
        severity: warning
        instance: "{{ \$labels.instance }}"
      annotations:
        summary: "instance: {{ \$labels.instance }} disk(/boot 分区) inode 使用率过高"
        description: "Disk (/boot 分区) inode 使用率超过 80%"
        value: "{{ \$value }}"
        
    - alert: NodeFilefdAllocatedPercentHigh
      expr: node_filefd_allocated{job="node"} / node_filefd_maximum{job="node"} * 100 > 80
      for: 10m
      labels:
        severity: warning
        instance: "{{ \$labels.instance }}"
      annotations:
        summary: "instance: {{ \$labels.instance }} filefd 打开百分比过高"
        description: "Filefd 打开百分比 超过 80%"
        value: "{{ \$value }}"

    - alert: NodeNetworkNetinBitRateHigh
      expr: avg by (instance) (irate(node_network_receive_bytes_total{device=~"eth0|eth1|ens33|ens37"}[1m]) * 8) > 20 * (1024 ^ 2) * 8
      for: 3m
      labels:
        severity: warning
        instance: "{{ \$labels.instance }}"
      annotations:
        summary: "instance: {{ \$labels.instance }} network 接收比特数 速率过高"
        description: "Network 接收比特数 速率超过 20MB/s"
        value: "{{ \$value }}"

    - alert: NodeNetworkNetoutBitRateHigh
      expr: avg by (instance) (irate(node_network_transmit_bytes_total{device=~"eth0|eth1|ens33|ens37"}[1m]) * 8) > 20 * (1024 ^ 2) * 8
      for: 3m
      labels:
        severity: warning
        instance: "{{ \$labels.instance }}"
      annotations:
        summary: "instance: {{ \$labels.instance }} network 发送比特数 速率过高"
        description: "Network 发送比特数 速率超过 20MB/s"
        value: "{{ \$value }}"
        
    - alert: NodeNetworkNetinPacketErrorRateHigh
      expr: avg by (instance) (irate(node_network_receive_errs_total{device=~"eth0|eth1|ens33|ens37"}[1m])) > 15
      for: 3m
      labels:
        severity: warning
        instance: "{{ \$labels.instance }}"
      annotations:
        summary: "instance: {{ \$labels.instance }} 接收错误包 速率过高"
        description: "Network 接收错误包 速率超过 15个/秒"
        value: "{{ \$value }}"

    - alert: NodeNetworkNetoutPacketErrorRateHigh
      expr: avg by (instance) (irate(node_network_transmit_packets_total{device=~"eth0|eth1|ens33|ens37"}[1m])) > 15
      for: 3m
      labels:
        severity: warning
        instance: "{{ \$labels.instance }}"
      annotations:
        summary: "instance: {{ \$labels.instance }} 发送错误包 速率过高"
        description: "Network 发送错误包 速率超过 15个/秒"
        value: "{{ \$value }}"

    - alert: NodeProcessBlockedHigh
      expr: node_procs_blocked{job="node"} > 10
      for: 10m
      labels:
        severity: warning
        instance: "{{ \$labels.instance }}"
      annotations:
        summary: "instance: {{ \$labels.instance }} 当前被阻塞的任务的数量过多"
        description: "Process 当前被阻塞的任务的数量超过 10个"
        value: "{{ \$value }}"

    - alert: NodeTimeOffsetHigh
      expr: abs(node_timex_offset_seconds{job="node"}) > 3 * 60
      for: 2m
      labels:
        severity: info
        instance: "{{ \$labels.instance }}"
      annotations:
        summary: "instance: {{ \$labels.instance }} 时间偏差过大"
        description: "Time 节点的时间偏差超过 3m"
        value: "{{ \$value }}"
EDG
}

function one() {
  Load
  Node
  Cadvisor
  Writeprometheus
  Writerules
  Prometheus
  Grafana
}

function two() {
  Load
  Node
  Cadvisor
  Writealertprometheus
  Writealert
  Writerules
  Alertmanager
  Prometheus
  Grafana
}

echo "###################################################"
echo "###	1、只部署监控+可视化界面	        ###"
echo "###                                             ###"
echo "###	2、监控+可视化界面+邮件告警             ###"
echo "###################################################"

read -t 300 -p "请输入您要执行的选项：" Option
  case $Option in
    1)
      echo "正在为您部署监控+可视化界面"
      one
      ;;
    2)
      echo "正在为您部署监控+可视化界面+邮件告警"
      two
      ;;
    *)
      echo "请输入选项1|2，否则将会终止脚本！"
      exit
  esac 
