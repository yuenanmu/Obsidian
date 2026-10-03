---
title: CookRPC 架构与文件职责说明
tags:
  - 项目架构
  - C++
  - RPC
  - CookRPC
project: CookRPC
type: 源码阅读笔记
source_repo: https://github.com/CppTrainingHub/rpc-tutorial
local_repo: rpcframework/
created: 2026-10-02
---

# CookRPC 架构与文件职责说明

> [!info] 本文定位
> 这是一份**照着源码写出来的**架构说明，不是照抄 README。
> 目的是让你在没有跑起来之前，也能知道「每个文件是干什么的」「谁调用谁」「一次调用经过哪些文件」。
> 配套的完成度判断见 [[CookRPC源码闭环审计与训练计划对照]]。

> [!warning] 阅读前提
> 本次审读**只做静态精读**（52 个手写源文件、约 6800 行全部过了一遍），**没有编译、没有装依赖、没有运行**。
> 因此下文所有「实现完整 / 有缺口」的判断都来自代码路径推演；凡属推断我会明确标注。

---

## 一、项目定位

| 项 | 内容 |
|---|---|
| 项目名 | CookRPC（CMake `project(cookrpc VERSION 1.0)`） |
| 本质 | 一个**教学用自研 RPC 框架**，从零实现：配置、日志、注册中心、负载均衡、线程池、压缩、加解密、序列化、协议、网络、服务注册 |
| 语言/标准 | C++17（`CMAKE_CXX_STANDARD 17`） |
| 依赖 | protobuf、absl、nlohmann_json、spdlog(+fmt)、zstd、cryptopp、zookeeper（全部经 vcpkg） |
| 平台 | **仅 Linux / macOS**（`sys/socket.h`、`fcntl`、`unistd.h`、epoll / kqueue；用的是 GCC/Clang 专有编译选项） |
| 规模 | 手写代码 52 文件 ≈ 6 800 行；protoc 生成代码 2 文件 ≈ 1 094 行 |
| 构建产物 | `rpc_server`、`rpc_client`、`stress_test_client` 三个可执行文件 |

> [!note] 关于 Windows
> 仓库**不能直接在 Windows 上构建**：`rpc_client.h` 第 8–9 行直接 `#include <sys/socket.h>` / `<netinet/in.h>`；`CMakeLists.txt` 第 122–125 行用 `-Wno-deprecated-declarations` 这类 GCC/Clang 参数，MSVC 会报错；`rpc_build.sh` 写死 `/root/.vcpkg/installed/x64-linux/...`。
> 想在 Windows 上跑，只能走 **WSL2**。

---

## 二、顶层目录结构

```
rpcframework/                     ← 仓库根
├── CMakeLists.txt                构建入口：找依赖、收集源文件、生成 3 个可执行文件
├── README.md                     安装依赖 / 编译 / 运行 / 压测 的简明说明
├── rpc_build.sh                  一键构建脚本：先 protoc 生成 pb，再 cmake 构建
├── stress_test.sh               压测驱动脚本：调用 build/stress_test_client
├── count_lines.py                代码行数统计小工具（不参与构建）
├── test.cpp                      结构体对齐/内存布局的练手文件（不参与构建）
├── CookRPC项目学习计划进度表.md     训练计划（你加入的，非原作者文件）
│
├── config/                       运行时配置（3 个 json）
│   ├── rpc_server.json           服务端：监听地址/端口/线程池/ZK/负载均衡策略
│   ├── rpc_client.json           客户端：ZK 地址/命名空间/超时/重试
│   └── servers.json              要注册到 ZK 的服务实例清单（IP:Port）
│
├── docs/
│   └── MASTER_KEY_GUIDE.md       主密钥配置指南 ⚠️ 描述的是"应该怎么做"，代码里没实现
│
├── protos/                       业务消息定义（演示用）
│   ├── message.proto             HelloRequest / HelloResponse（package minirpc）
│   ├── message.pb.h/.cc          protoc 生成物，已入库
│   └── compile_proto.sh          单独编译 proto 的脚本
│
├── utils/                        通用基础设施
│   ├── log_manager.h             spdlog 封装 + LOG_xxx / CLIENT_xxx 宏
│   └── util_fun.h/.cpp           IP 合法性校验（死代码，且有 bug）
│
└── rpc_src/                      全部业务源码（12 个模块目录）
    ├── core/                     ★ 组装层：两个 main + 客户端门面 + 演示服务 + 错误码
    ├── network/                  ★ 网络层：epoll 事件循环、连接、监听 socket
    ├── protocol/                 ★ 协议层：RpcHeader / RpcRequest / RpcResponse 编解码
    ├── service/                  服务接口 + 服务注册表与分发
    ├── registry/                 ZooKeeper 节点注册（临时节点）
    ├── conn_balancer/            ZooKeeper 连接管理 + 3 种负载均衡器
    ├── load_config/              4 组配置类
    ├── thread_pool/              ★ 自研线程池 + 单例包装
    ├── compress_data/            zstd 压缩解压
    ├── encrypt/                  加解密（名为 AES，实为自定义移位密码）
    ├── serializer/               json / protobuf 序列化（header-only）
    └── tools/                    压测客户端
```

---

## 三、总体架构（分层视图）

```
┌──────────────────────────────────────────────────────────────────────┐
│                          core/  （组装层）                            │
│  servers_main.cpp  ── 装日志/配置/线程池/监听socket/Service/ZK注册    │
│  client_main.cpp   ── 演示：同步调用 + 300 次异步调用                 │
│  rpc_client.h/.cpp ── 客户端门面：发现→连接→序列化→压缩→加密→收发     │
│  rpc_service.h     ── 演示服务 RpcService（唯一方法：Echo，JSON）     │
│  error_code.h      ── 错误码 + 文案                                   │
└───────────┬───────────────────────────────────┬──────────────────────┘
            │                                   │
   ┌────────▼─────────┐              ┌──────────▼──────────┐
   │ network/         │              │ service/            │
   │ MessageCycle     │──分发────────▶│ ServiceManager      │
   │ (epoll/kqueue)   │              │ (name→Service 映射)  │
   │ Connection       │              │ Service(抽象接口)    │
   │ ConnectionManager│              └─────────────────────┘
   │ CreateSocket     │
   └────┬────────┬────┘
        │        │
        │        └──────────────▶ thread_pool/  ThreadPool + ThreadPoolSingleton
        │                              (优先级队列、动态扩缩、优雅关闭)
        │
   ┌────▼─────────────────────────────────────────────────────┐
   │ protocol/   RpcHeader(magic+len+seq) + RpcRequest/RpcResponse │
   │             ← 紧挨着 serializer/ compress_data/ encrypt/      │
   └──────────────────────────────────────────────────────────┘

   配置与发现侧（客户端/服务端都用）：
   load_config/ ──▶ conn_balancer/ ──▶ registry/
   (4 个 Config)     (ZkConnHandler +   (ServiceRegistry
                      随机/轮询/加权)     临时节点注册)
```

### 模块依赖方向（实际调用关系）

```
core          → network, service, protocol, conn_balancer, load_config, thread_pool, serializer, compress_data, encrypt
network       → service, protocol, thread_pool, connection_manager, compress_data, encrypt
service       → thread_pool
conn_balancer → registry, load_balancer, load_config(ServiceRegistryConfig)
load_config   → conn_balancer(ZkConnHandler, LoadBalancer)   ⚠️ 反向依赖（配置类顺带初始化全局单例）
registry      → zookeeper C API
serializer    → nlohmann/json, protobuf
```

> [!caution] 一个架构上的坏味道
> `load_config/rpc_server_config.cpp` 第 48–67 行在**解析 JSON 的过程中顺手初始化了两个全局单例**（`ZkConnHandler`、`LoadBalancer`）。
> 也就是说「读配置」这个动作带了副作用，而且**顺序敏感**：如果 `rpc_server.json` 里没有 `scheduler` 段，`ZkConnHandler` 就不会被初始化，但 `servers_main.cpp` 第 167–169 行照样会去注册服务 → 用一个空的 host 和未初始化的 port 去连 ZK。
> 这让 `RpcServerConfig` 从「纯配置对象」变成了「有状态的编排器」。

---

## 四、协议格式（`protocol/`）

### 4.1 头部 `RpcHeader`（12 字节，无 padding）

| 偏移 | 长度 | 字段 | 说明 |
|---|---|---|---|
| 0 | 4 | `magic_number` | 固定 `0x12345678`（`rpc_protocol.cpp:7`） |
| 4 | 4 | `message_length` | **body** 长度（不含头本身） |
| 8 | 4 | `sequence_id` | 请求序列号 |

### 4.2 `RpcRequest::Serialize` 的 body 布局（`rpc_protocol.cpp:9-56`）

```
[uint32 len][service_name 字节][uint32 len][method_name 字节][uint32 len][payload 字节]
```

`payload` 就是**用户业务数据经过序列化后的字符串**（JSON 文本或 protobuf 二进制）。

### 4.3 `RpcResponse::Serialize` 的 body 布局（`rpc_protocol.cpp:146-198`）

```
[uint32 len][result_data][uint32 len][error_message][uint32 error_code][uint32 sequence_id]
```

> [!warning] 两处不对称，值得注意
> 1. `RpcRequest::Deserialize` **没有**校验 `header.message_length` 与实到字节数是否一致；`RpcResponse::Deserialize` 第 225 行**校验了**。请求侧少一道完整性检查。
> 2. 头部/长度都是**本机字节序**直接 `memcpy`，没有 htonl/ntohl → 只能同架构通信，跨大小端会错。

### 4.4 线缆上真正传输的东西（关键！）

协议头**不是** TCP 分帧头，而是**被加密载荷的内部结构**。实际写到 socket 上的是：

```
Base64( [用主密钥加密的 32 字节会话密钥] [用会话密钥加密的 zstd(协议头+body)] )
```

**TCP 层没有任何长度前缀。** 这是后面所有分帧问题的根源（详见审计文档 B1）。

---

## 五、一次 RPC 调用的完整链路

以 `client_main.cpp` 的 `testSyncCall()`（Echo / JSON）为例：

### 客户端发起（进程 `rpc_client`）

| # | 位置 | 动作 |
|---|---|---|
| 1 | `client_main.cpp:109` | `RpcClient client("../config/rpc_client.json")` |
| 2 | `rpc_client.cpp:69-97` | 读 `rpc_client.json` → 超时/重试/ZK 命名空间 → 初始化 `ZkConnHandler` |
| 3 | `rpc_client.cpp:208-271` | `Connect()`：向 ZK 要一个 server 地址 → 建非阻塞 socket → `select` 等连接完成 → 包成 `Connection` |
| 4 | `zk_conn_handler.cpp:321` | `getServer()` → `updateServersFromZk()` → `getAllServers()`（`zoo_get_children` + 逐个 `zoo_get`） |
| 5 | `zk_conn_handler.cpp:331` | `LoadBalancer::selectServer(servers_)` 选一台 |
| 6 | `rpc_client.h:126-176` | `prepareAndSerializeRequest()`：业务对象 → `SerializerManager::serialize` → 填 `RpcRequest` → `RpcRequest::Serialize` → `ZstdCompress` → `AesEncrypt` |
| 7 | `rpc_client.cpp:305-319` | `sendAndReceiveResponse()` → `Connection::Write(密文)` |
| 8 | `rpc_client.h:181-247` | `processResponse()`：`ReadWithTimeout` → 解密 → 解压 → `RpcResponse::Deserialize` → 校验 error_code → 反序列化出业务对象 |

### 服务端处理（进程 `rpc_server`）

| # | 位置 | 动作 |
|---|---|---|
| 9 | `servers_main.cpp:134` | `CreateSocket::Create(...)` 建监听 socket |
| 10 | `servers_main.cpp:143-156` | `MessageCycle` + `AddListenFd` |
| 11 | `servers_main.cpp:159-164` | `ServiceManager::RegisterService(RpcService)` |
| 12 | `servers_main.cpp:167-173` | `zk_handler.registerServicesFromConfig()` → 在 ZK 建**临时节点** `/cookrpc/cookrpc_service/<ip>:<port>` |
| 13 | `servers_main.cpp:179` | `message_cycle->Loop()` 进入事件循环 |
| 14 | `message_cycle.cpp:574` | `epoll_wait` → `HandleEpollEvents` |
| 15 | `message_cycle.cpp:259-337` | 新连接：`accept` → 设非阻塞 + `TCP_NODELAY` → 建 `Connection` → **注册 `EPOLLIN \| EPOLLET`（边缘触发）** → 挂回调 |
| 16 | `connection.cpp:115-174` | `Read()` 循环读到 `EAGAIN`，累积进 `read_buffer_` |
| 17 | `connection.cpp:176-257` | `ProcessMessage()`：解密 → 解压 → `RpcRequest::Deserialize` → 触发 `message_callback_` |
| 18 | `message_cycle.cpp:339-378` | `HandleRpcRequest` → `HandleRpcRequestAsync` → 提交到线程池（`HIGH` 优先级） |
| 19 | `message_cycle.cpp:380-431` | 线程池里执行 `HandleRpcRequestSync`：`ValidateRequest` → `ServiceManager::HandleRpcRequest` |
| 20 | `service_manager.h:111-131` | 按服务名查到 `RpcService` → `HandleRequest("Echo", payload, result)` |
| 21 | `rpc_service.h:16-50` | 业务逻辑：解析 JSON，拼一段固定欢迎语 + 回显 message |
| 22 | `message_cycle.cpp:466-498` | `SendResponse()`：`RpcResponse::Serialize` → zstd → 加密 → `conn->Write()` |
| 23 | `connection.cpp:259-295` | `Write()` 写 `write_buffer_` 并尝试 `write(2)` |

### 闭环结论（一句话）

**Echo/JSON 这条 happy path 是通的**，条件是：**单机 loopback、报文小到一次 `read` 能读完、无并发、目标 socket 不阻塞**。
一旦出现 TCP 半包/粘包、并发请求、或写缓冲满，链路会断掉或静默产生错误数据 —— 原因见 [[CookRPC源码闭环审计与训练计划对照]] 的断裂点清单。

---

## 六、逐文件职责表

### 6.1 根目录

| 文件 | 类型 | 职责 | 备注 |
|---|---|---|---|
| `CMakeLists.txt` | 构建 | 找 7 个 vcpkg 依赖；`file(GLOB_RECURSE)` 收集公共源文件（排除 `core/`）；定义 `rpc_server` / `rpc_client` / `stress_test_client` 三个 target；统一包含目录与链接库 | 第 44 行 `serializer/*.cpp` 的 glob 实际**匹配不到文件**（该目录只有 .h），不会报错，属死配置 |
| `README.md` | 文档 | 依赖清单、`./rpc_build.sh`、运行两个可执行文件、压测脚本用法 | 第 11–12 行的路径 `./rpc-tutorial/build/...` 与当前仓库名 `rpcframework` 不一致，是**过时残留** |
| `rpc_build.sh` | 脚本 | ① 用 vcpkg 的 protoc 生成 `*.pb.h/cc` ② `rm -rf build` 后 cmake 配置 + 多核构建 | 写死 `VCPKG_ROOT=/root/.vcpkg`、`x64-linux`；`rm -rf build` 每次全量重建 |
| `stress_test.sh` | 脚本 | 检查 `build/stress_test_client` 是否存在 → 组装参数 → 运行 → 日志落临时文件并汇总 | 参数：`-c` 并发数、`-r` 每客户端请求数、`-t` 持续秒数 |
| `count_lines.py` | 工具 | 统计代码行/空行/注释行 | **不参与构建**，纯辅助 |
| `test.cpp` | 练手 | `__attribute__((aligned))`、`#pragma pack` 下结构体内存布局的实验 | **不在 CMake glob 范围内**，是作者的学习草稿，可以忽略 |
| `.gitignore` | 配置 | 忽略 `logs/` `example/` `build/` `stress_test_results.txt` `sync.sh` | 注意 `build/` 被忽略 → 仓库里**没有构建产物** |
| `CookRPC项目学习计划进度表.md` | 文档 | 训练计划与你的进度勾选 | 你加入的，原仓库没有 |

### 6.2 `config/`

| 文件 | 职责 | 关键字段 | 备注 |
|---|---|---|---|
| `rpc_server.json` | 服务端配置 | `servers_name_prefix`、`servers_ip`、`servers_port`=8989、`max_connections`=800000、`timeout`、`scheduler{zk_host,zk_port,zk_namespace,retry_interval,load_balance_strategy}`、`thread_pool{max_threads,core_threads,queue_size,keep_alive_time}`、`load_balance_strategy`、`register_config` | ⚠️ `max_connections: 800000` 会被截断（见审计 S3）；⚠️ `thread_pool.core_threads` 代码**从未读取**（S2）；⚠️ `scheduler.retry_interval` 键名与代码读取的 `zk_retry_interval` 不匹配 |
| `rpc_client.json` | 客户端配置 | `zk_host`、`zk_port`、`zk_namespace`=`/cookrpc/cookrpc_service`、`server_port`、`timeout_ms`、`retry_times` | ⚠️ `server_port` 被解析并存下来了，但**连接时不用**（永远走 ZK），是孤儿字段；⚠️ 没有任何负载均衡策略字段 |
| `servers.json` | 要注册的服务实例清单 | `service_name`=`cookrpc_service`、`service_version`、`registry_nodes[{address,port}]` | ⚠️ 里面是**原作者的公网 IP `124.221.19.77`** 和 `0.0.0.0`；`0.0.0.0` 作为客户端要连的服务地址是无效的（原作者注释说明只是为了演示负载均衡）；`service_version` 无人读取 |

### 6.3 `utils/`

| 文件 | 职责 |
|---|---|
| `log_manager.h` | 定义 11 个日志宏：`LOG_TRACE/DEBUG/INFO/WARN/ERROR/FATAL` + `CLIENT_INFO/DEBUG/WARN/ERROR/FATAL`（对应训练计划「开1.2 使用宏定义的形式打印日志」）；`Logger::GetInstance().Init()` 建控制台 sink + `daily_file_sink` 写 `../logs/cookrpc.log`，设为 spdlog 默认 logger；为 `fmt::formatter<std::thread::id>` 加了特化（配合日志格式里的 `%t`） |
| `util_fun.h/.cpp` | 只有一个 `IsValidIpAddress(const std::string&)`：用正则校验 IPv4。⚠️ **全仓库无人调用**（死代码），而且正则外层多包了一层捕获组，导致第 4 段八位组**从未被校验**（`1.2.3.999` 会返回 true）。客户端实际用的是 `inet_pton`（`rpc_client.cpp:112`） |

### 6.4 `rpc_src/load_config/`（配置加载器，对应「开2」）

| 文件 | 职责 | 备注 |
|---|---|---|
| `rpc_server_config.h/.cpp` | 服务端配置单例：解析 `rpc_server.json` → 监听参数、线程池参数、注册清单；**并顺手初始化 `ZkConnHandler` 和 `LoadBalancer`** | 副作用式初始化，顺序敏感（见上文坏味道） |
| `rpc_client_config.h/.cpp` | 客户端配置单例：解析 `rpc_client.json` | `GetServerPort()` 无调用者；`json::parse` 没有 try/catch（服务端那份有） |
| `thread_pool_config.h/.cpp` | 线程池参数：`max_threads`、`queue_size`、`keep_alive_time` | ⚠️ **没有解析 `core_threads`**，`core_threads_` 默认 0 |
| `registry_config.h/.cpp` | 解析 `servers.json` → `service_name` / `service_version` / `registry_nodes` | ⚠️ 这个头文件**没有 `#pragma once`**（全仓库唯一）；`LoadBalanceStrategy` 枚举定义了但没人用（实际用字符串） |

### 6.5 `rpc_src/conn_balancer/`（注册中心交互 + 负载均衡，对应「开3/开4/开5」）

| 文件 | 职责 | 备注 |
|---|---|---|
| `load_balancer.h/.cpp` | 抽象基类 `LoadBalancer`（纯虚 `select`）+ 单例 `getInstance()` + `initBalancer(type)` + 静态入口 `selectServer()`；工厂用 `unordered_map<string, factory>` 注册 `random`/`round`/`weight` 三种策略 | `getInstance()` 无人调用；`createRandomBalancer` 等 3 个自由工厂函数**只有声明没有定义**；`instance_` 的双重检查锁在锁外读 `shared_ptr`（数据竞争） |
| `random.h` | `RandomLoadBalancer`：`mt19937` 均匀随机挑一台 | `gen_` 无锁，多线程调用有竞争 |
| `round.h` | `RoundRobinLoadBalancer`：`atomic::fetch_add(1) % size` | 三个里实现最规整的一个 |
| `weight.h` | `WeightedRoundRobinLoadBalancer`：按权重区间选实例 | ⚠️ **权重被硬编码为 1**（第 20 行注释也承认"简单处理"）→ 退化成普通轮询；`weights_` 表和 `setWeight()` 是够不着的死代码 |
| `zk_conn_handler.h/.cpp` | 全仓库**唯一真正操作 ZooKeeper 的客户端侧模块**：`initZkConnHandler` 建连；`getAllServers` 用 `zoo_get_children` + `zoo_get` 拉取 `/命名空间/子节点` 的值；`getServer` 调负载均衡器选一台；`registerService(s)` 通过 `ServiceRegistry` 建临时节点；`updateServersFromZk` 刷新本地缓存 | ⚠️ **没有任何 watch**：所有 ZK 调用 `watch` 参数都是 0，`global_watcher`（第 411–435 行）算完状态字符串后**什么都不做**；⚠️ `getServer` 每次都同步拉一次 ZK；⚠️ `cleanup()` 用函数内 `static atomic` 守卫 → **一个进程只能清理一次** |

### 6.6 `rpc_src/registry/`（「开3 Zookeeper 节点注册模块」）

| 文件 | 职责 | 备注 |
|---|---|---|
| `service_registry.h/.cpp` | 自己持有一个独立 ZK 连接（`zoo_handle_`），负责真正把服务写成 **临时节点**：`ensurePath("/cookrpc/服务名")` → `createNode("/cookrpc/服务名/IP:Port", ZOO_EPHEMERAL)`。临时节点在连接断开时自动消失 —— 这是服务发现能感知宕机的机制 | ⚠️ 头文件第 18–20 行只有一行注释 `// 发现服务`，**发现接口根本不存在**（发现能力实际在 `ZkConnHandler` 里）；`ROOT_PATH` 写死 `/cookrpc`，**完全忽略配置里的 `zk_namespace`**；`is_connected_` 是普通 `bool`，ZK 事件线程写、主线程读，有数据竞争；构造函数空转 5 秒后即使没连上也照样"成功"返回；`string_completion_cb` / `strings_completion_cb` 是死回调；类定义在**全局命名空间**（其他都在 `cookrpc`） |

### 6.7 `rpc_src/thread_pool/`（「开6 自己实现一个线程池」，规模最大的模块，~1000 行）

| 文件 | 职责 |
|---|---|
| `thread_pool.h` | 定义 `TaskPriority{LOW,NORMAL,HIGH}`、`ThreadPoolState{RUNNING,PAUSED,SHUTTING_DOWN,STOPPED}`、`ThreadPoolStruct` 配置、`TaskWrapper`（`std::function` + 优先级，重载 `operator<` 供 `priority_queue` 排序）、`ThreadPool`；`enqueue` 模板在头文件内实现：`packaged_task` + `get_future` 拿返回值，队列满时用 `not_full_condition_` 做背压，任务数 > 活跃线程数时调 `adjust_thread_count()` 扩容 |
| `thread_pool.cpp` | 两个构造函数（固定大小 / 按配置动态）、`worker_thread`（`wait_for` + 谓词等待、取任务、执行、统计、空闲回收）、`pause/resume`、`shutdown`（两阶段优雅关闭）、`stop_now`、`get_stats`、`adjust_thread_count` |
| `thread_pool_singleton.h` | header-only 单例外壳，`instance_` 是 `unique_ptr<ThreadPool>`：`init` / `getInstance` / `enqueue` / `getStats` / `getQueueSize` / `getPoolSize` / `pause` / `resume` / `shutdown` / `destroy` / `exists` / `getState` |
| `thread_pool_singleton.cpp` | **只定义了两个静态成员**（`instance_`、`mutex_`），其余是注释。**与 `thread_pool.cpp` 没有任何重复逻辑** |
| `README.md` | 线程池集成说明 | ⚠️ 文档提到 `HandleBatchRpcRequests` 批量接口，**全仓库不存在**（只在 README 里出现）；把 `thread_pool_singleton.cpp` 说成"单例实现"也不准确（实现全在 .h） |

### 6.8 `rpc_src/compress_data/`（「开7 压缩模块」，实现完整）

| 文件 | 职责 |
|---|---|
| `zstd_compress.h/.cpp` | `ZstdCompress` 单例（Meyers singleton），封装 zstd 一次性 API：`CompressString` / `DecompressString` / `CompressData` / `DecompressData` + `GetCompressBound`；压缩级别枚举 `FASTEST=1 / DEFAULT=3 / BETTER=7 / BEST=19 / MAX=22`，作为**运行时参数**贯穿四个方法（所以"多种压缩级别"是真实满足的）；错误统一用 `ZSTD_isError` 判定 |

### 6.9 `rpc_src/encrypt/`（「开8 Encrypt 加解密模块」）

| 文件 | 职责 | 备注 |
|---|---|---|
| `aes_encrypt.h/.cpp` | `AesEncrypt` 单例，对外只有 `Encrypt` / `Decrypt`。内部：`Base64Encode/Decode`（自实现）、`ShiftEncrypt/ShiftDecrypt`。加密流程 = ① 随机生成 32 字节会话密钥 ② 用会话密钥移位加密数据 ③ 用主密钥移位加密会话密钥 ④ 拼成 `[加密的会话密钥][加密的数据]` 再做 Base64 | ⚠️ **它不是 AES**：头文件第 18–20 行自己写明"实际使用的是自定义的移位加密算法"，算法本体是 `(c + k + i%256) % 256` 的逐字节加法密码；⚠️ **主密钥硬编码在 `aes_encrypt.cpp:91`**；⚠️ 无 IV/nonce、无 MAC → `Decrypt` 对错误密钥/被篡改数据**仍返回 true**；⚠️ `GenerateKey()` 只有声明没有定义；⚠️ CMake 链接了 Crypto++ 但代码里**从未 include 过** |

### 6.10 `rpc_src/serializer/`（「开9 CookRPC 序列化模块」）

| 文件 | 职责 | 备注 |
|---|---|---|
| `json_serializer.h` | `JSONSerializer::serialize/deserialize`，基于 nlohmann/json 的 `dump()` / `parse()+get<T>()` | header-only；出错返回 `""`/`false`，没有错误通道 |
| `protobuf_serializer.h` | `ProtobufSerializer::serialize/deserialize`，基于 `SerializeAsString()` / `ParseFromString()` | header-only；包含生成的 `message.pb.h` |
| `serializer_manager.h` | `enum class SerializeType{JSON,PROTOBUF}` + `SerializerManager::serialize/deserialize`，用 `if constexpr` 按类型分派 | ⚠️ **它不是工厂/注册表**：没有注册机制、没有 map、没有运行期按类型查表，只有编译期 `if constexpr`；JSON 分支要求 `T` **恰好是** `nlohmann::json`，否则**编译通过但运行期静默返回空串** |

> [!note] 为什么 `serializer/` 没有 .cpp
> 三个文件全是模板，header-only。因此 `CMakeLists.txt:44` 的 `"${RPC_SOURCE_DIR}/serializer/*.cpp"` glob 展开为空列表 —— `file(GLOB_RECURSE)` 匹配不到不会报错，所以构建不受影响，模板只在各调用方 TU 里实例化。

### 6.11 `rpc_src/protocol/`（「开10 RPC 协议定义模块」）

| 文件 | 职责 |
|---|---|
| `rpc_protocol.h` | `RpcHeader`（`MAGIC`/`message_length`/`sequence_id`）、抽象基类 `RpcMessage`（纯虚 `Serialize`/`Deserialize` + `sequence_id`）、`RpcRequest`（service_name / method_name / payload）、`RpcResponse`（result_data / error_message / error_code） |
| `rpc_protocol.cpp` | 手写二进制编解码：`memcpy` 头部 + 三段「长度前缀 + 字节」；反序列化时逐段做边界检查并校验魔数；`RpcHeader::MAGIC = 0x12345678` |

### 6.12 `rpc_src/network/`（「开12 网络模块」，~1400 行）

| 文件 | 职责 | 备注 |
|---|---|---|
| `create_socket.h/.cpp` | 封装监听 socket：`socket` → `SO_REUSEADDR` → `bind` → `listen(backlog)`，另有 `Accept()` 与客户端 socket 选项设置 | 有两个 `Create` 重载（参数版 / 配置对象版） |
| `connection.h/.cpp` | 单条连接对象（`enable_shared_from_this`）：`Read()` 边缘触发下循环读到 `EAGAIN`；`Write()` 先塞 `write_buffer_` 再尝试 `write(2)`；`ProcessMessage()` 负责「解密 → 解压 → 反序列化 → 回调」；`ReadWithTimeout()` 用 `select`；状态机 `CONNECTED/DISCONNECTING/DISCONNECTED`；缓冲上限 `MAX_BUFFER_SIZE=64KB` | ⚠️ `Read()` 在 `EAGAIN` 时永远 `return true`；⚠️ `ProcessMessage` 先把**整个读缓冲**当一条密文解密，只用 `buffer.size() >= sizeof(RpcHeader)` 当"够了"的判据；⚠️ 处理完一条就 `clear()` 整个缓冲；⚠️ `write_buffer_` 无锁；`SendInBuffer()`/`is_writing_` 是死声明 |
| `connection_manager.h/.cpp` | 单例 `ConnectionManager`：`unordered_map<fd, shared_ptr<Connection>>` + 互斥锁，提供 `AddConnection` / `RemoveConnection` / `GetConnection` / `GetConnectionCount` / `CloseAll` | 用 `shared_ptr` 管生命周期是对的 |
| `message_cycle.h/.cpp` | 事件循环与 RPC 编排（~650 行）：`kqueue`(macOS) / `epoll`(Linux) 二选一；`AddListenFd` / `RemoveListenFd`；`HandleNewConnection`（`accept` + 非阻塞 + `TCP_NODELAY` + 注册 `EPOLLIN\|EPOLLET`）；`HandleClientData`；**`HandleRpcRequest(Async/Sync)` 提交线程池并走 `ServiceManager` 分发**；`SendResponse`（序列化+压缩+加密+写回）；`ValidateRequest`；`Loop` / `Stop` | ⚠️ 构造函数里**重新注册了 SIGINT**，覆盖掉 `servers_main.cpp` 装的那个；`stop_flag` 是文件级 `static`；`AddListenFd` 用**水平触发**、客户端连接用**边缘触发**（混用，本身可以，但要小心） |

### 6.13 `rpc_src/service/`（「开11 RPC 服务注册模块」）

| 文件 | 职责 |
|---|---|
| `service.h` | 服务抽象接口：`GetServiceName()` + `HandleRequest(method, args, result)` —— 一个服务可以挂多个方法 |
| `service_manager.h` | 单例 `ServiceManager`：`RegisterService`（按服务名去重注册）、`GetService`、`HandleRpcRequest(Sync/Async)`；`HandleRpcRequestAsync` 走线程池 `HIGH` 优先级，`HandleRpcRequestSync` 是内部实现 | 
> 注意：真正被调用的是**同步**版本（`message_cycle.cpp:399`，注释写着"避免双重异步"）；`HandleRpcRequestAsync` 无人调用。

### 6.14 `rpc_src/core/`（「开13 核心模块组装」）

| 文件 | 职责 | 备注 |
|---|---|---|
| `servers_main.cpp` | 服务端入口与组装：建日志 → 读配置 → 建线程池 → 建监听 socket → 建 `MessageCycle` 并挂监听 fd → 注册 `RpcService` → 向 ZK 注册实例 → `Loop()`；实现了信号处理与 `GracefulShutdown()`（关监听、`CloseAll` 连接、`shutdown` 线程池、`cleanup` ZK） | ⚠️ `signal()` 装的处理器会被 `MessageCycle` 构造函数覆盖 |
| `client_main.cpp` | 客户端入口：建 `RpcClient` → 演示同步调用 → 演示 300 次异步调用（每次 sleep 100ms）；错误处理用例被注释掉 | 是**演示程序**，不是正经测试 |
| `rpc_client.h` | 客户端门面（大部分模板实现都在头里）：`Call<Response,Request>(service, method, request, serialize_type, response)`（全程持 `mutex_`）、`AsyncCall`（`std::async` + 同一个 `Call`）、`prepareAndSerializeRequest`（序列化→RpcRequest→压缩→加密）、`processResponse`（解密→解压→反序列化→查错） | ⚠️ 没有请求-响应按 `sequence_id` 配对；⚠️ 持锁粒度过大导致异步是"假并发" |
| `rpc_client.cpp` | 实现构造/析构、`loadConfig`、`initSocket`（非阻塞）、`Connect`（向 ZK 要地址 + 重试建连）、`Disconnect`、`Reconnect`、`GenerateSequenceId`、`sendAndReceiveResponse`、`validateServerInfo`、`tryConnect`、`waitForConnection` | ⚠️ `GetServerAddress` 有声明无定义；`waitForConnection` 有定义无人调用 |
| `rpc_service.h` | **演示服务** `RpcService`：`GetServiceName()` 返回 `"RpcService"`；`HandleRequest` 只认一个方法 `"Echo"` —— 解析入参 JSON，回一段固定欢迎语 + `received_message` 回显 | 这是**唯一**注册的业务服务；`protos/message.proto` 里的 `HelloRequest/HelloResponse` 与它无关，从未被使用 |
| `error_code.h` | `enum class ErrorCode`（`SUCCESS`、`INVALID_REQUEST`、`SERVICE_NOT_FOUND`、`INTERNAL_ERROR` 等）+ `Error::getErrorMessage()` 文案表 | 被 `rpc_client.h` 和 `message_cycle.cpp` 用于响应码 |

### 6.15 `rpc_src/tools/`

| 文件 | 职责 |
|---|---|
| `stress_test_client.cpp` | 压测客户端（**不是单元测试**）：自己解析 `-n/-c/-t/-s` 参数；用 `RpcClient` 起 `concurrent_clients` 个 `std::thread`，每个线程循环调用 `RpcService::Echo`；统计 QPS/成功率/延迟。由 CMake 生成 `stress_test_client` target |

### 6.16 `protos/`

| 文件 | 职责 | 备注 |
|---|---|---|
| `message.proto` | 演示用业务消息：`package minirpc;` + `HelloRequest{string name=1}` / `HelloResponse{string greeting=1}` | ⚠️ 包名 `minirpc` 是旧名残留；⚠️ 这两个消息**从未被任何代码使用**，`RpcService` 用的是 nlohmann::json |
| `message.pb.h` / `message.pb.cc` | protoc 生成物（已入库，1094 行） | 生成时 protobuf 版本 `5029003`（v29.x），构建时会按 `PROTOBUF_VERSION` 检查 |
| `compile_proto.sh` | 单独调 protoc 生成 pb 文件的脚本 | 同样写死 `/root/.vcpkg/.../x64-linux/tools/protobuf/protoc` |

### 6.17 `docs/`

| 文件 | 职责 | 备注 |
|---|---|---|
| `MASTER_KEY_GUIDE.md` | 主密钥的生成/配置/轮换指南（337 行）：讲 4 级密钥来源优先级、密钥生成工具、Docker/K8s/systemd 部署、安全最佳实践 | ⚠️ **描述的东西代码里几乎都没实现**：`COOKRPC_MASTER_KEY` 环境变量、`config/master_key.txt`、`/etc/cookrpc/master_key`、`~/.cookrpc/master_key` 这四级查找在全部 `.h/.cpp` 里**一次都没出现**；它引用的 `tools/generate_master_key` 工具不存在；引用的 `ENCRYPTION_DETAILS.md`、`DEPLOYMENT_GUIDE.md`、`SECURITY_CHECKLIST.md` 三个兄弟文档也都不存在。实质上是**"目标设计"文档，不是"现状"文档** |

---

## 七、构建组织

### 7.1 三个 target 的源文件组成（`CMakeLists.txt:34-90`）

```
COMMON_SOURCES = rpc_src/{compress_data,conn_balancer,encrypt,load_config,
                          network,protocol,registry,service,thread_pool,serializer}/*.cpp
               + utils/*.cpp
               + protos/*.cc
   └─ 过滤掉文件名含 test / demo / main 的（排除 core/ 下的两个 main）

rpc_server          = COMMON_SOURCES + core/servers_main.cpp
rpc_client          = COMMON_SOURCES + core/rpc_client.cpp + core/client_main.cpp
stress_test_client  = COMMON_SOURCES + core/rpc_client.cpp + tools/stress_test_client.cpp
```

> [!tip] 理解 CMake 的两个要点
> 1. `rpc_service.h` 是**头文件**，不需要单独编译 —— 它被 `servers_main.cpp` include 进去才有代码。
> 2. `core/` 目录**不参与 glob**（因为里面有 main），所以 `rpc_client.cpp` 必须被三个 target 各自显式列出。

### 7.2 依赖与链接（`CMakeLists.txt:22-28, 113-120`）

```cmake
find_package(Protobuf CONFIG REQUIRED)      # 业务消息
find_package(absl CONFIG REQUIRED)          # protobuf 的依赖
find_package(nlohmann_json CONFIG REQUIRED) # JSON 配置与业务数据
find_package(spdlog CONFIG REQUIRED)        # 日志
find_package(zstd CONFIG REQUIRED)          # 压缩
find_package(cryptopp CONFIG REQUIRED)      # ⚠️ 链接了但代码从未使用
find_package(zookeeper CONFIG REQUIRED)     # 注册中心
```

编译宏：`THREADED`、`ZK_DEPRECATED=1`（zookeeper C 客户端需要）。macOS 上额外设置 `arm64` 架构。

### 7.3 依赖版本没有锁定 ⚠️

仓库里**没有 `vcpkg.json`、没有 `vcpkg-configuration.json`、没有 `CMakePresets.json`、没有 CI 配置**。
所有依赖的版本完全取决于你本机 vcpkg 装到哪一版 —— 这意味着**环境不可复现**，别人（包括你自己换台机器）很可能因为 protobuf/zookeeper 版本差异而构建失败。这是从零上手时最容易踩的坑。

---

## 八、平台与运行约束汇总

| 约束 | 具体表现 |
|---|---|
| 只能 Linux/macOS | `sys/socket.h`、`netinet/in.h`、`arpa/inet.h`、`unistd.h`、`fcntl.h`、`select`、`epoll`/`kqueue` 直接使用 |
| 编译选项是 GCC/Clang 专有 | `-Wno-deprecated-declarations`、`-Wno-unused-parameter`；MSVC 会直接报错 |
| 构建脚本写死路径 | `rpc_build.sh`：`VCPKG_ROOT="/root/.vcpkg"`、`x64-linux/tools/protobuf/protoc` |
| 配置路径相对 CWD | `servers_main.cpp:101` 用 `"../config/rpc_server.json"`、`client_main.cpp:109` 用 `"../config/rpc_client.json"`、日志默认 `"../logs"` —— 都假设**从 build/ 目录里启动** |
| 必须有一个可用的 ZooKeeper | 服务端启动时连不上 ZK 会直接 `return 1` 退出（`servers_main.cpp:169-173`）；客户端发现也强依赖 ZK |
| 字节序 | 协议头/长度直接 `memcpy`，无网络字节序转换 → 同架构才能通信 |

---

## 九、建议的阅读顺序

按「从入口到细节」，效率最高：

1. **`CMakeLists.txt`** —— 先看清有哪三个可执行文件、源文件怎么拼的
2. **`rpc_src/core/servers_main.cpp`** —— 服务端启动的 13 个步骤，是全项目的目录
3. **`rpc_src/core/client_main.cpp`** + **`rpc_src/core/rpc_client.h`** —— 客户端怎么发起一次调用（重点看 `prepareAndSerializeRequest` 和 `processResponse` 这一对逆操作）
4. **`rpc_src/protocol/rpc_protocol.h/.cpp`** —— 搞清楚「头 12 字节 + 三段长度前缀」的线上格式
5. **`rpc_src/network/message_cycle.cpp`** —— epoll 事件循环怎么转、请求怎么被丢进线程池（重点 `HandleRpcRequestSync`、`SendResponse`）
6. **`rpc_src/network/connection.cpp`** —— `Read` / `ProcessMessage` / `Write` 三件套（**这里的问题最多，建议对照审计文档读**）
7. **`rpc_src/thread_pool/thread_pool.h/.cpp`** —— 独立模块，值得单独精读（优先级队列 + 背压 + 动态扩容 + 优雅关闭）
8. **`rpc_src/service/service.h` + `service_manager.h` + `core/rpc_service.h`** —— 服务怎么注册、怎么按方法分发（很短）
9. **`rpc_src/conn_balancer/` + `registry/`** —— ZooKeeper 的两个用途：注册（临时节点）与发现（拉子节点），以及三种负载均衡器
10. **`rpc_src/load_config/` + `utils/`** —— 配置与日志，结构简单，最后看

---

## 十、和其他文档的关系

| 文档 | 内容 |
|---|---|
| 本文 | 架构、协议格式、调用链路、**每个文件干什么** |
| [[CookRPC源码闭环审计与训练计划对照]] | 闭环判定、断裂点清单（带 file:line 证据）、**训练计划 28 个单元逐项对照**、上手补齐清单 |

> [!success] 一句话总结本文
> 这不是一个"没写完的空架子"：**12 个模块目录全部有对应的真实代码**，配置、日志、线程池、压缩、协议、网络、服务分发都是能看出设计意图的实现。
> 但它是一个**"每层都通了、每层都没收尾"**的骨架：测试、依赖锁定、协议健壮性、并发安全这些"工程闭环"的部分基本空白。
