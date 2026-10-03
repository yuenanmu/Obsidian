---
title: CookRPC 源码闭环审计与训练计划对照
tags:
  - 项目审计
  - C++
  - RPC
  - CookRPC
project: CookRPC
type: 源码审计报告
source_repo: https://github.com/CppTrainingHub/rpc-tutorial
local_repo: rpcframework/
created: 2026-10-02
---

# CookRPC 源码闭环审计与训练计划对照

> [!abstract] 一句话结论
> **"能跑通一次调用"的闭环已经打通**，但只在「单机 loopback + 小报文 + 无并发」这组条件下成立；
> **工程意义上的闭环没有完成** —— 没有测试、没有依赖锁定、协议缺分帧、写路径会丢数据、并发写有竞争。
> 而且：**你原来的判断需要修正** —— 这个仓库**不是**"只做了前期准备"，**训练计划阶段二的 13 个开发单元全部已有对应代码**，只是每一层都没做工程化收尾。

---

## 0. 先说三件事

### ① 仓库的管理关系（你的 fork 流程已经配置对了）

```
upstream  → https://github.com/CppTrainingHub/rpc-tutorial   （私有的原仓库，只读参考）
origin    → https://github.com/yuenanmu/rpcframework         （你自己的仓库）
当前分支  → feature/rpc_init
```

- 你的 `HEAD` 相对 `upstream/main` **只多了一个提交**：`3b4bfbc docs:提交第一次PR,fork源码库并且添加一个计划表`（只加了那份计划表，**源码一行没改**）。
- `origin/main` 与 `upstream/main` **完全一致**（`git log upstream/main..origin/main` 为空）。
- 所以：**源码是"一次性导入"进来的**。`git log` 只有 2 个提交，第 2 个是 `23bb2a2 Import local GitLab source snapshot` —— 原作者的开发历史被压平成了一个快照提交。这意味着**你无法从 git 历史看出原作者哪部分是先写的、哪部分是后来补的**，只能靠读代码判断。

### ② 判定方法与证据边界（必须先说清楚）

| 做了什么 | 说明 |
|---|---|
| ✅ 静态精读 | 52 个手写源文件（约 6 800 行）**全部读过**，逐个函数、逐个调用点追踪 |
| ✅ 交叉验证 | 用全仓库 grep 核对「函数是否被调用」「配置字段是否被消费」「宏是否生效」 |
| ❌ 未编译 | 没有 vcpkg、没有装 6 个 C++ 依赖 |
| ❌ 未运行 | 没有 ZooKeeper、没有起服务端/客户端 |
| ❌ 未跑测试 | 见下 —— **仓库里其实没有单元测试可跑** |

**证据强度分级**：下文带 `file:line` 的都是我直接读到的代码事实；带「推断」标注的是基于代码路径的推理，未经运行验证。
仓库里**没有 `build/` 目录**（`.gitignore` 也忽略了 `build/`），说明这份 checkout 从未在本机构建过。

### ③ 仓库里没有单元测试

全仓库 grep：`gtest` / `catch2` / `doctest` / `enable_testing` / `add_test` / `CTest` —— **零命中**；没有 `tests/` 目录；CMake 里没有 test target。

所谓"测试"只有三个东西：
1. `stress_test_client.cpp` + `stress_test.sh` —— **压测工具**（测吞吐，不测正确性）
2. `client_main.cpp` —— **演示程序**（打两条日志说 success 或 failed）
3. `test.cpp`（仓库根目录）—— **结构体对齐的练手文件**（`sizeof`/`alignof`/`#pragma pack`），**不参与构建**，是死代码

> [!warning] 这直接影响你的计划
> 训练计划里 **学14.5「单元测试，测试 protobuf 的序列化和反序列化能力」** 和 **开6.1「自己完成一个线程池的开发，并进行测试」** 这两条验收标准，**在原仓库里找不到任何对应的测试代码**。如果你想"跑一下他的测试"，是跑不起来的 —— 没有测试。你只能自己写。

---

## 一、闭环链路：逐段验证

我把一次 `RpcClient::Call(...)` 从头到尾拆成 15 段，逐段判它「是否真实实现」「是否真的接到主链路上」。

图例：✅ 真实实现且已接入主链路　△ 实现了但有缺陷/接线不对　✘ 缺失或空实现

### 客户端发起

| # | 环节 | 位置 | 判定 | 依据 |
|---|---|---|---|---|
| 1 | 读配置 | `rpc_client_config.cpp:17-24` | ✅ | 6 个字段全部 `config.value()` 解析 |
| 2 | 连 ZooKeeper | `zk_conn_handler.cpp:216-299` | ✅ | 真 `zookeeper_init` + 状态轮询 |
| 3 | 服务发现（拉节点） | `zk_conn_handler.cpp:321→383→83` | ✅ | 真 `zoo_get_children` + 逐节点 `zoo_get`，返回 `ip:port` 列表 |
| 4 | 负载均衡选一台 | `zk_conn_handler.cpp:331` → `load_balancer.cpp:96` | △ | 代码是真的，但**客户端进程里从没调用过 `initBalancer`** → 永远走 `random` 兜底（详见 S1） |
| 5 | 建 TCP 连接（带重试） | `rpc_client.cpp:208-271` | ✅ | 非阻塞 socket + `select` 等完成 + `getsockopt(SO_ERROR)` 复核，重试 `retry_times` 次 |
| 6 | 业务对象序列化 | `rpc_client.h:135` | ✅ | `SerializerManager::serialize` → JSON 文本 |
| 7 | 装进 RpcRequest | `rpc_client.h:144-155` | ✅ | 填 service/method/payload/sequenceId，再二进制序列化 |
| 8 | 压缩 + 加密 + 发送 | `rpc_client.h:160-176` → `rpc_client.cpp:310` | ✅ | zstd → 自定义移位加密 → `write(2)` |

### 服务端处理

| # | 环节 | 位置 | 判定 | 依据 |
|---|---|---|---|---|
| 9 | 监听 + epoll 循环 | `message_cycle.cpp:38, 152-161, 574` | ✅ | `epoll_create1` + `EPOLLIN` 监听 fd + `epoll_wait(1000ms)` |
| 10 | accept 新连接 | `message_cycle.cpp:259-331` | ✅ | `accept` → 非阻塞 → `TCP_NODELAY` → `EPOLLIN\|EPOLLET` 注册 |
| 11 | 收数据 | `connection.cpp:115-174` | △ | 边缘触发循环读，但 `:139` 的 `return has_read_data \|\| !has_read_data;` 是**恒真式**，且 `n<4096` 时提前 `break` |
| 12 | **分帧 + 解密解压反序列化** | `connection.cpp:176-257` | ✘ | **先解密后判长度**，把"整个读缓冲"当一条密文；TCP 层没有长度前缀（详见 B1） |
| 13 | 丢给线程池异步处理 | `message_cycle.cpp:346-378` | ✅ | `ThreadPoolSingleton::enqueue(HIGH, ...)`，并按 `future.valid()` 判断提交是否成功 |
| 14 | 服务分发 + 业务执行 | `service_manager.h:111-131` → `rpc_service.h:20-49` | ✅ | 按服务名查表 → `HandleRequest("Echo", ...)` |
| 15 | 回包（序列化+压缩+加密+写回） | `message_cycle.cpp:466-498` | △ | 流水线对称，但 `EAGAIN` 时**直接丢弃未发完的数据**（详见 B2） |

### 客户端收响应

| # | 环节 | 位置 | 判定 | 依据 |
|---|---|---|---|---|
| 16 | 读响应 | `rpc_client.h:184` → `connection.cpp:72-113` | △ | `select` + 一次 `Read`，**没有"读到完整消息为止"的重组逻辑** |
| 17 | 解密→解压→反序列化→查错 | `rpc_client.h:200-243` | ✅ | 逆流水线完整，并校验 `errorCode` |

### 闭环结论

> [!success] 通的
> **序列化 → 压缩 → 加密 → 传输 → 解密 → 解压 → 反序列化** 这条流水线**完全对称、没有任何一段被注释掉**，两端都真实实现了。
> 加上 ZooKeeper 注册/发现、线程池异步处理、服务按名分发 —— **最小可用闭环成立**。

> [!failure] 不成立的条件
> 下面任意一条出现，闭环就断：
> - **报文跨 TCP 分段**（半包）→ 解密失败/解压失败 → 服务端**直接关连接**（B1）
> - **两个请求挤在一次 read 里**（粘包）→ 只处理第一条，第二条**被静默丢弃**（B1-②）
> - **响应没一次写完**（`EAGAIN`）→ 尾部数据**永久丢失**，客户端超时（B2）
> - **同一连接上并发处理**（线程池多 worker 同时写）→ `write_buffer_` 数据竞争（B3）
> - **客户端并发调用** → 因为全程持一把锁，实际是串行的"假异步"（B4）

---

## 二、断裂点清单

### 🔴 A 级：会丢数据 / 功能不正确（5 条）

#### B1 — 没有 TCP 分帧，半包直接断连、粘包静默丢弃

**位置**：`connection.cpp:176-257`（收），`message_cycle.cpp:466-498`（发）

发送侧写进 socket 的是：
```
Base64( [主密钥加密的32字节会话密钥] [会话密钥加密的 zstd( RpcHeader + body )] )
```
**没有任何 TCP 长度前缀。** 长度信息 `RpcHeader.message_length` 藏在**密文里面** —— 不先解密就拿不到。

接收侧的判断逻辑（`connection.cpp:179`）是：
```cpp
if (read_buffer_.size() >= sizeof(RpcHeader))   // 注意：这是"密文的字节数 ≥ 12"
```
用"密文 ≥ 12 字节"当作"一条消息收全了"，**语义上毫无意义**（Base64 之后 12 字节连一个密钥前缀都不够）。然后它直接把**整个读缓冲**丢去解密（`:198`）。

后果分两种：
- **半包**：TCP 只到了一部分 → AES 变体解出来是垃圾 → zstd 解压失败（`ZSTD_isError`）→ `ProcessMessage` 返回 false → `message_cycle.cpp:527-532` **直接 `RemoveConnection(fd)` 关掉连接**。用户侧表现为"大报文随机失败"。
- **粘包/管线化**：一次 read 到了两条完整请求 → 只解出第一条 → `connection.cpp:248` **`read_buffer_.clear()` 把第二条一起扔掉**，且没有"循环抽取"的逻辑。更糟的是自研 `Base64Decode` 遇到第一个 `=` 就停（`aes_encrypt.cpp:197`），第二条要么被丢弃要么污染明文。

**修法**（这也是训练计划里没提但工程上必须做的）：
1. 在**加密之前**套一层长度前缀，或者独立于加密在 TCP 层加 `[u32 total_len]`；
2. 接收侧改成「先读 4 字节长度 → 攒够 `length` 字节 → 再解密 → 循环抽取下一条」；
3. `read_buffer_` 只在**确认完整取出**一条后才 erase 掉那一段，不是整个 clear。

#### B2 — 写缓冲满了就丢数据，且没有 EPOLLOUT 兜底

**位置**：`connection.cpp:259-295`

```cpp
while (!write_buffer_.empty()) {
    ssize_t n = write(fd_, write_buffer_.data(), write_buffer_.size());
    if (n < 0) {
        if (errno == EAGAIN || errno == EWOULDBLOCK) break;   // ← 剩下没发完的数据就留在这儿了
        ...
    }
    write_buffer_.erase(...);
}
return true;   // 但返回的是"成功"
```

- 非阻塞 socket 上 `EAGAIN` 是**正常现象**（对端接收窗口满了），不是错误；
- 代码 `break` 之后 `return true` → 调用方以为发完了；
- **全仓库 grep `EPOLLOUT` / `EPOLL_CTL_MOD`：零命中** —— 没有任何"可写时继续发"的机制；
- `Connection::SendInBuffer()`（`connection.h:67`）**只有声明，既没有定义也没有调用**；`is_writing_`（`connection.h:81`）声明了从未使用。

也就是说**"写回压"这条路根本没修**。一旦响应大到超过 socket 发送缓冲（大 body、慢客户端、压测高并发），响应就永久丢失，客户端只能超时。

#### B3 — 响应在工作线程里写连接，而连接缓冲没有任何锁

**位置**：`message_cycle.cpp:357-362`（提交线程池）→ `:494 conn->Write()`（**worker 线程执行**）　vs　`connection.cpp:115-174`（**epoll 线程读**）

`Connection` 的成员 `read_buffer_` / `write_buffer_` / `state_` / `fd_` 全部**裸访问，无互斥锁**：

```cpp
// connection.h:72-81
std::vector<char> read_buffer_;
std::vector<char> write_buffer_;
State state_ = State::DISCONNECTED;
std::atomic<bool> is_writing_ = false;   // ← 唯一一个原子变量，但从未被使用
```

`ConnectionManager` 的 `mutex_` **只保护 `fd → conn` 这张表**，不保护 `Connection` 内部。

后果：同一连接上两个并发请求被两个 worker 处理时，两次 `conn->Write()` 会**同时 do `write_buffer_.insert()` 和 `erase()`** → 数据竞争（UB），且两条响应可能交错在一起，客户端解不出来。

**修法**：给 `Connection` 的写路径加锁（或者用 asio 那种 strand 串行化），并在写完后立刻 flush。

#### B4 — 客户端没有请求-响应配对，`AsyncCall` 是假并发

**位置**：`rpc_client.h:63`（`std::lock_guard` 全程持锁）、`:148`（生成 sequenceId）、`:222-243`（处理响应）

- `Call()` 从**检查连接**一路持锁到**读完响应**，整段是串行的；
- 响应里的 `sequence_id` **客户端从来不校验**（`processResponse` 只看了 `errorCode`）→ 收到错配的/重复的响应也照收；
- `AsyncCall`（`rpc_client.h:93-111`）只是 `std::async` 包了一层 `Call` → 300 个异步调用全部**排队等同一把锁**，实际是串行。

`client_main.cpp:48` 那个 300 次循环 + 每次 `sleep_for(100ms)`，看着像并发，其实是**顺序执行 + 睡眠**。

> 好消息：正因为"一次只有一个请求在飞"，B1 的粘包问题在演示场景下**不会触发**，这也是为什么作者能跑通。

#### B5 — 服务端是把"整个读缓冲"当密文解，明文长度校验只在响应侧有

**位置**：`rpc_protocol.cpp:58-144`（请求反序列化）vs `:200-294`（响应反序列化）

- `RpcResponse::Deserialize` 第 **225** 行校验了 `in.size() == sizeof(header) + header.message_length`；
- `RpcRequest::Deserialize` **没有任何**对应校验。

两侧不对称，请求侧少一道完整性检查 —— 这也是 B1 能在"看起来正常"的情况下潜伏的原因。

### 🟠 B 级：配置/接线错误，功能达不到宣称的效果（6 条）

| 编号 | 问题 | 位置 | 影响 |
|---|---|---|---|
| **S1** | **负载均衡策略在客户端进程里从未初始化** | `load_balancer.cpp:98-106`、`rpc_server_config.cpp:59-67` | `initBalancer()` **只在服务端读 `rpc_server.json` 时被调用**。客户端走的是 `RpcClientConfig`，**从不调用 `initBalancer`** → `selectServer` 每次打印 `"Load balancer not initialized, using default random balancer"` 并退化成随机。**`rpc_server.json` 里的 `"load_balance_strategy": "round"` 对客户端选路毫无影响** → 训练计划「开4.1 实现多种负载均衡器」的代码在，但**实际只跑随机那一个** |
| **S2** | `thread_pool.core_threads` **根本没被解析** | `thread_pool_config.cpp:10-33`（只读了 max_threads / queue_size / keep_alive_time）、`h:39`（`core_threads_ = 0`） | `servers_main.cpp:115` 把 `GetCoreThreads()` 传给线程池 → **线程池以 0 个工作线程启动**（配置里写的 8 被静默忽略）。因 `adjust_thread_count()` 会懒加载，功能不至于瘫痪，但 8 个核心线程的设置完全无效，且所有线程都可被空闲回收 |
| **S3** | `max_connections` 被 `uint16_t` 截断 | `rpc_server_config.h:54,46`、`cpp:25` | JSON 写的是 **800000**，`uint16_t` 只能存到 65535 → 实际变成 **13568**。静默变成错误值（顺带一提：内核 `listen()` backlog 本来也上限 `SOMAXCONN`，800000 本身就是个没意义的数） |
| **S4** | ZooKeeper **完全没有节点监听**，且每次都同步拉一遍 | `zk_conn_handler.cpp:99,118,411-435,321` | 所有 ZK 调用 `watch` 参数都是 **0**、watcher 传 `nullptr`；`global_watcher`（`:411-435`）**算完状态字符串后什么都不做**（不记日志、不更新标志、不重连、不重注册），注释自己写着"这里没有输出日志"。变更感知只能靠 `getServer()` **每次调用都同步 `zoo_get_children`** 拉一次（作者注释也承认"后期可优化为定时更新+内存缓存"）→ 训练计划「开5 Zookeeper 节点管理模块」只做到"能列出节点"，**管理（监听/缓存）是空壳** |
| **S5** | 加权轮询的权重恒为 1 | `weight.h:20` | `std::vector<int> weights(instances.size(), 1);` 上一行注释自认"这里简单处理" → **加权轮询退化成普通轮询**；`weights_` map 和 `setWeight()` 是 `private` 且无人调用，**想配权重都没接口** |
| **S6** | 日志：客户端不初始化、DEBUG 级编译期被消掉 | `log_manager.h:17-18,26,94`；`client_main.cpp` / `rpc_client.cpp`（无 `Init()`） | ① **客户端从不调 `Logger::GetInstance().Init()`** → 只能吃 spdlog 自带默认 logger，**没有文件日志**；② **`SPDLOG_ACTIVE_LEVEL` 全仓库未定义**（CMake 只定义了 `THREADED`、`ZK_DEPRECATED`）→ `LOG_DEBUG`/`LOG_TRACE`/`CLIENT_DEBUG` 展开为 `(void)0`，**编译期被删掉**，`set_level(trace)` 白设。已存在的调用点（`connection.cpp:137,154,229`、`message_cycle.cpp:225,240,247,376`、`rpc_client.h:245`）**静默失效** —— 你调试时会发现"打了日志却什么都没有"，原因在这 |

### 🟡 C 级：中等（8 条）

| 编号 | 问题 | 位置 |
|---|---|---|
| M1 | **protobuf 分支写好了但全仓库无人调用**：`SerializeType::PROTOBUF` 在三个调用点（`client_main.cpp:26,58,95`、`stress_test_client.cpp:57`）**全是 JSON**；`message.proto` 的 `HelloRequest/HelloResponse` **没有任何代码引用**。训练计划「开9.2 完成对 protobuf 的序列化」= 代码在，**从未被跑过** | `serializer_manager.h:34,73`；`message.proto` |
| M2 | **加密不是 AES**：`aes_encrypt.h:18-20` 自己写明"实际使用的是自定义的移位加密算法"；本体是 `(c + k + i%256) % 256` 的逐字节加法密码；**主密钥硬编码在 `aes_encrypt.cpp:91`**（`"CookRPC_Secret_Key_2024_Production!@#$%^&*"`）；**无 IV、无 MAC** → `Decrypt` 对错误密钥/篡改数据**仍返回 true**（`:391-397`），篡改一个密文字节→对应一个明文字节变化，不可检测。CMake 链接了 Crypto++（`:27,114`）但**代码里从未 include** | `aes_encrypt.cpp:91,260-275,367-404` |
| M3 | **`docs/MASTER_KEY_GUIDE.md` 描述的东西代码里全都没有**：文档讲了 4 级密钥来源（`COOKRPC_MASTER_KEY` 环境变量 / `config/master_key.txt` / `/etc/cookrpc/master_key` / `~/.cookrpc/master_key`）、一个 `tools/generate_master_key` 生成工具、3 个兄弟文档（`ENCRYPTION_DETAILS.md` 等）——全仓库 grep：**这些标识符只出现在这个 markdown 里**，工具不存在，兄弟文档不存在。**这是一份"目标设计"文档，不是现状文档** | `docs/MASTER_KEY_GUIDE.md:70-124,31-41,319-323` |
| M4 | **孤儿配置字段**（JSON 里有、代码不读，或读了不用）：`rpc_client.json.server_port`（`GetServerPort()` 零调用）、`servers.json.service_version`（`GetServiceVersion()` 零调用）、`rpc_server.json.scheduler.retry_interval`（**键名错配**：代码读的是 `zk_retry_interval`，永远取默认 5）、`scheduler.load_balance_strategy`（与顶层键重复，只有顶层被读）、`scheduler.zk_namespace`（存进 `zk_namespace_` 后从未被读） | 见各 config 与 `zk_conn_handler.cpp:170-177` |
| M5 | 线程池三处实质缺陷：**①** shutdown 竞态 —— `tasks_.pop()` 在锁内（`thread_pool.cpp:123`）但 `active_threads_++` 在锁外（`:142`），而 `shutdown` 的完成条件是 `tasks_.empty() && active_threads_==0`（`:269`）→ **可能提前返回"全部完成"**；**②** `tasks_failed_` 恒为 0 —— 任务经 `packaged_task` 调用会**吞掉异常**，`catch` 分支（`:162-175`）永不触发，失败任务被当成 completed 计数；**③** 非核心线程回收 `return` 时（`:98`）把已死的 `std::thread` 留在 `workers_` 里只减计数 → 向量只增不减，`size()` 报的是死线程数 | `thread_pool.cpp:95-98,121-123,142,162-175,269` |
| M6 | **配置里带着原作者的公网 IP**：`servers.json:6` 是 `124.221.19.77`，`:11` 把 `0.0.0.0:8989` 也注册成一个服务实例（`0.0.0.0` 作为客户端要连的地址是无效的；`zk_conn_handler.cpp:501-503` 注释说明这是**故意为了演示负载均衡**才注册多个）| `config/servers.json` |
| M7 | **两个 SIGINT 处理器互相覆盖**：`servers_main.cpp:81` 装了 `SignalHandler`（置 `g_shutdown_requested`），但 `MessageCycle` 构造函数（`message_cycle.cpp:47`）**又装了一个** `signalHandler`（置文件级 `stop_flag`）→ 后装的把先装的顶掉。优雅关闭最终靠 `atexit` 兜到，但 `g_shutdown_requested` 永远不会被置位，日志会打 `"Unexpected exit"`。另外 `cleanup()` 用**函数内 `static atomic`** 守卫（`zk_conn_handler.cpp:352-355`）→ **一个进程只能真正清理一次**，之后重建的 ZK 句柄永不关闭（泄漏） | 见左 |
| M8 | **没有 `vcpkg.json`** → **依赖版本完全没锁**。仓库里只有 `CMakeLists.txt` 的 `find_package(...)`（无版本要求），没有 manifest、没有 `CMakePresets.json`、没有 CI。换台机器/换个时间装 vcpkg，拿到的 protobuf / spdlog / zookeeper 版本都可能不同 → **环境不可复现**，这也是下面「能不能编译」最大的风险来源 | 仓库根目录 |

### 🟢 D 级：轻微（死代码与文档瑕疵）

| 类别 | 明细 |
|---|---|
| **声明了但没定义**（一旦被调用就是链接错误） | `RpcClient::GetServerAddress`（`rpc_client.h:43`）、`Connection::SendInBuffer`（`connection.h:67`）、`AesEncrypt::GenerateKey`（`aes_encrypt.h:49`）、`CreateSocket::SetClientSocketOpt`（`create_socket.h:31`）、`createRandomBalancer`/`createRoundRobinBalancer`/`createWeightedBalancer`（`load_balancer.h:47-49`） |
| **定义了但没人调用** | `RpcClient::waitForConnection`（`rpc_client.cpp:189`）、`BytesToHexString`（`aes_encrypt.cpp:62`）、`IsValidIpAddress`（`util_fun.cpp:4`）、`connection_manager` 之外的所有 `LoadBalancer::getInstance()`、`ServiceManager::HandleRpcRequestAsync`、`Connection::Write(const RpcResponse&)`（且它会**跳过压缩和加密**）、`string_completion_cb`/`strings_completion_cb` |
| **声明了从未使用** | `Connection::is_writing_`、`MessageCycle::thread_id_`、`ServiceRegistry::` 的 `BLOCK_SIZE`、`ZkConnHandler` 的 `running_`/`zk_namespace_`/`retry_interval_`、`LoadBalanceStrategy` 枚举、`MAX_MESSAGE_SIZE`（只定义不校验，真正生效的是 `MAX_BUFFER_SIZE=64KB`） |
| **`util_fun.cpp` 的 IP 校验有 bug** | 正则外层多包了一层捕获组 → `match[1]` 是整串 → 循环检查的是 `match[1..4]` = 整串前缀 + 前 3 段，**第 4 段永远不校验** → `"1.2.3.999"` 返回 `true`。反正是死代码，客户端用的是 `inet_pton`（`rpc_client.cpp:112`） |
| **头文件缺 include guard** | `registry_config.h` 是**全仓库唯一**没有 `#pragma once` 的头（第 1 行直接是注释）。目前只因没有任何 TU 重复包含它才没报错 |
| **热路径刷日志** | `thread_pool.h:281` 在**持队列锁的情况下**每个任务入队都打一条 `LOG_INFO`；`thread_pool.cpp:126` 每次取任务再打一条 → 压测时日志会成为瓶颈 |
| **spdlog 用了 printf 格式符** ⚠️ | `create_socket.cpp` 的 **9 处** `LOG_ERROR("... errno: %d, error: %s", errno, strerror(errno))`（行 86,110,130,167,175,184,192,198,206）—— `LOG_ERROR` 展开成 `SPDLOG_ERROR` 即 **fmt**，fmt 不认 `%d/%s`。详见下面「能不能编译」 |
| **`stress_test.sh` 的结论块是坏的** | 第 211-227 行读 `$success_rate` / `$qps` / `$failed_requests`，**这三个变量在脚本里从未被赋值** → `bc` 收到空操作数，建议文本无意义；脚本也从不把 host/port 传给二进制（客户端的 `-h` 是 help） |
| **`stress_test_client.cpp` 默认路径是作者机器的绝对路径** | 第 30 行 `"/usr/team_project/rpc-tutorial/config/rpc_client.json"`，与它自己的 help 文本（`../config/...`）矛盾；每请求还硬 `sleep_for(1ms)`（`:119,134`）→ 单客户端 QPS 被压到约 1000 |
| **`count_lines.py` 的注释计数有 bug** | 单行 `/* ... */` 会因先判 `/*` 就 `continue`（`:28-31`）而漏判 `*/`，导致**后续所有行都被当成注释** |
| **文档/注释与实现不符** | `thread_pool/README.md` 提到的 `HandleBatchRpcRequests` **全仓库不存在**（只在 README 里）；`README.md` 的运行路径写的是 `./rpc-tutorial/build/...`（仓库名是 `rpcframework`）；`registry_config.cpp` 注释提到 `registry_config.json`（实际文件是 `servers.json`）；`message.proto` 的包名还是旧名 `minirpc` |

---

## 三、能不能编译？—— 你没法测，但这是最该先知道的事

你说了没法安装环境测试。虽然我也没编译，但**静态检查已经发现 3 个高度可疑的编译/构建风险点**，按优先级：

### ⚠️ 风险 1：protobuf 版本被硬锁死在 5.29.3

`protos/message.pb.h` 第 14-19 行：

```cpp
#include "google/protobuf/runtime_version.h"
#if PROTOBUF_VERSION != 5029003
#error "Protobuf C++ gencode is built with an incompatible version of"
#error "Protobuf C++ headers/runtime. See ..."
#endif
```

**生成的 pb 代码要求运行期 protobuf 恰好是 5.29.3**，差一个版本就 `#error` 直接编译失败。
而仓库**没有 `vcpkg.json`**（M8）→ 你 `vcpkg install protobuf` 拿到的很可能是别的版本 → **开箱即挂**。
**解决**：要么把 protobuf 固定到 5.29.3，要么用同样的 protoc 5.29.3 重新生成 pb 文件（`protos/compile_proto.sh` 就是干这个的，但它写死了 `/root/.vcpkg/...` 路径）。

### ⚠️ 风险 2：`create_socket.cpp` 的 9 处 printf 格式符

`LOG_ERROR` → `SPDLOG_ERROR` → `spdlog::error(fmt, args...)` → **fmt 的格式串**。
而代码写的是 `"create socket error, errno: %d, error: %s"` 并传了两个参数。

- 在**较新的 fmt/spdlog（fmt ≥ 9 / spdlog ≥ 1.10，当前 vcpkg 基本都会装到）**下，字面量格式串会在**编译期**被检查，格式串里没有 `{}` 却给了参数 → fmt 报 **"unused arguments"**，**编译失败**；
- 在**较老的版本**下能编过，但 `%d/%s` 不被替换，**参数被静默丢弃**，日志里只有字面串。

无论哪种，都是问题。**同文件里其他地方（`:120,149,159`）用的是正确的 `{}`**，说明这是遗漏而非风格。全部改成 `{}` 即可。

### ⚠️ 风险 3：编译器/平台

- `CMakeLists.txt:122-125` 用 `-Wno-deprecated-declarations` / `-Wno-unused-parameter` —— **GCC/Clang 专用**，MSVC 直接报错；
- 一堆 POSIX 头（`sys/socket.h`、`netinet/tcp.h`、`pthread.h`、`sys/epoll.h`）+ `epoll`/`kqueue` —— **Windows 原生不能编**，必须 WSL2/Linux/macOS；
- `rpc_build.sh` 写死 `VCPKG_ROOT=/root/.vcpkg`，必须以 root 身份、装在这个路径下。

> [!tip] 结论
> **能不能编译，取决于你装到的 protobuf 是否恰好 5.29.3、以及 spdlog/fmt 的版本。**
> 这是"跑起来"的第一个门槛，而且和下面的补齐清单是同一件事。

---

## 四、训练计划逐项对照

### 4.1 阶段二 · 项目开发（13 个单元）

**表格读法**：「代码是否存在」= 文件里有没有对应实现；「是否接入主链路」= 运行时会不会真的走到；「完成度」是我给的判定。

| # | 计划里的单元 | 对应文件 | 代码存在 | 接入主链路 | 完成度 | 缺口 |
|---|---|---|---|---|---|---|
| 开1 | 日志模块：spdlog | `utils/log_manager.h` | ✅ | ✅（仅服务端） | **70%** | 客户端从不 `Init()` → 无文件日志；`SPDLOG_ACTIVE_LEVEL` 未定义 → DEBUG/TRACE 编译期消失；无 `LOG_CRITICAL` |
| 开2 | 配置加载器：nlohmann/json | `load_config/` 4 组 | ✅ | ✅ | **75%** | 5 个孤儿/错配字段（M4）；`core_threads` 没解析（S2）；`max_connections` 截断（S3）；两个 loader 的 `json::parse` 无 try/catch |
| 开3 | Zookeeper **节点注册**模块 | `registry/service_registry.cpp` | ✅ | ✅ | **90%** | 真实可用（临时节点 + 递归建父路径 + 幂等）。瑕疵：`ROOT_PATH` 忽略配置、`is_connected_` 数据竞争、类在全局命名空间、5s 自旋后不报错 |
| 开4 | 负载均衡模块 | `conn_balancer/load_balancer.*` + `random/round/weight.h` | ✅ | ❌ **接线错误** | **50%** | 三个均衡器都真的能选出实例，但**客户端进程从不 `initBalancer`** → 永远随机（S1）；`weight` 权重恒为 1（S5）；`getInstance` 无人调用、3 个工厂函数只有声明 |
| 开5 | Zookeeper **节点管理**模块 | `conn_balancer/zk_conn_handler.*` | ✅ | ⚠️ 部分 | **45%** | "列出节点"真实可用；**"监听/管理"完全没有**（`watch=0`，`global_watcher` 空壳，S4）；每次调用同步拉 ZK；`cleanup()` 一辈子只跑一次 |
| 开6 | 自己实现一个线程池 | `thread_pool/` 4 文件 ~1000 行 | ✅ | ✅ | **85%**（全项目完成度最高） | 真实优先级队列 + 背压 + 动态扩容 + 优雅关闭 + 统计。缺口：shutdown 竞态、`tasks_failed_` 恒 0、`workers_` 只增不减（M5）；**没有单元测试**（计划要求"并进行测试"） |
| 开7 | 压缩模块：zstd | `compress_data/zstd_compress.*` | ✅ | ✅ | **95%** | 压/解对称、5 个级别真实贯穿、错误检查齐全。小瑕疵：`<mutex>` 未用、空析构、拒绝无 content-size 的帧 |
| 开8 | Encrypt 加解密模块 | `encrypt/aes_encrypt.*` | ✅ | ✅ | **40%** | **不是 AES**（作者自己承认）；主密钥硬编码；无 IV、无 MAC、篡改不报错；`GenerateKey()` 只声明；"开8.3 也可以使用其他加解密方式"这句救回了它 —— 但**不能当成 AES 写进简历** |
| 开9 | CookRPC 序列化模块 | `serializer/` 3 个 .h | ✅ | ⚠️ 一半 | **60%** | JSON 路径真实在用；**protobuf 路径写好但全仓库无人调用**（M1）；`SerializerManager` 不是工厂/注册表，只是编译期 `if constexpr`，类型不对会**静默返回空串** |
| 开10 | RPC 协议定义模块 | `protocol/rpc_protocol.*` | ✅ | ✅ | **80%** | 头部（magic/len/seq）+ 三段长度前缀，编解码完整。缺口：**请求侧不校验 `message_length`**（响应侧校验了，不对称）；无协议版本号；**裸 `memcpy` 不做字节序转换**；响应里 `sequence_id` 存了两遍 |
| 开11 | RPC 服务注册模块 | `service/service.h` + `service_manager.h` + `core/rpc_service.h` | ✅ | ✅ | **75%** | 按服务名注册/分发真实可用。缺口：**只有一个演示服务 `RpcService`、只有一个方法 `Echo`**；方法分发是服务内部的 `if (method_name == "Echo")` 硬编码链，没有方法表/反射；`HandleRpcRequestAsync` 无人调用且有空指针解引用风险 |
| 开12 | CookRPC 网络模块（network） | `network/` 4 组 ~1400 行 | ✅ | ✅ | **60%** | epoll/kqueue + 非阻塞 + `TCP_NODELAY` + accept/read/close/错误处理**都真实实现**。缺的正是最难的部分：**TCP 分帧（B1）**、**写回压与 EPOLLOUT（B2）**、**连接缓冲加锁（B3）**；`Loop()` 在调用线程里跑（单线程 Reactor，这本身合理，但 `thread_id_` 是死成员） |
| 开13 | 核心（Core）模块组装 | `core/servers_main.cpp`、`client_main.cpp`、`rpc_client.*`、`error_code.h` | ✅ | ✅ | **75%** | 日志/配置/线程池/监听/服务/ZK注册 全部串起来了，还有信号处理 + `GracefulShutdown`（关监听、`CloseAll`、shutdown 线程池、cleanup ZK），这是**全项目最能体现"组装完成"的地方**。缺口：两个 SIGINT 处理器互相覆盖（M7）；客户端无请求-响应配对、异步假并发（B4） |

**统计**：13/13 个单元**都有对应代码**；其中「真实可用、能上主链路」的约 **7 个**（开2/3/6/7/11/13 + 开10 的编解码），「接线或实现有明显缺口」的 **6 个**（开1/4/5/8/9/12）。

### 4.2 阶段一 · 学习准备（15 个单元）

这一阶段是**环境/工具/规范的学习项**，大部分**无法从仓库里验证**，但能看出几件事：

| # | 计划里的单元 | 仓库能证明什么 |
|---|---|---|
| 学1 | 项目介绍与需求分析 | 无法验证（纯理解题） |
| 学2 | 项目开发环境搭建 | ⚠️ **反面证据**：没有 `vcpkg.json`/manifest/CI → 环境不可复现；`rpc_build.sh` 写死 `/root/.vcpkg` 和 `x64-linux` |
| 学3 | 工具安装（vcpkg/spdlog/zookeeper/zstd/nlohmann_json） | ✅ 7 个依赖都在 `CMakeLists.txt` 里 `find_package` 了（还多了 protobuf、cryptopp、absl）；⚠️ 但 protobuf 被 pb.h 硬锁 5.29.3 |
| 学4 | C++ 代码规范 | ⚠️ 代码有大量注释、命名基本规范，但存在**前后不一致**：同一个文件里 `{}` 与 `%d/%s` 混用（`create_socket.cpp`）、`std::cout` 与 logger 混用（`service_registry.cpp`）、全局命名空间与 `cookrpc` 命名空间混用 |
| 学5 | 分支 & 代码提交规范 | ✅ 有分支 `feature/rpc_init`，提交信息带 `docs:` 前缀（看得出用了 Conventional Commits）。⚠️ 但源码是一次性 `Import local GitLab source snapshot` 导入，**看不到小步提交的过程** |
| 学6 | nlohmann/json | ✅ 配置加载 + 业务数据 + `RpcService` 的 Echo 都在用 |
| 学7 | spdlog | ✅ 用了 spdlog + fmt + 双 sink（控制台 + 每日文件）；⚠️ 见开1 的缺口 |
| 学8 | zstd 压缩工具 | ✅ 5 个压缩级别枚举 + 真实 API 调用 |
| 学9 | zookeeper | ✅ 用了 C 客户端（`zookeeper_init` / `zoo_create` / `zoo_get_children` / `zoo_get` / `zoo_exists`）；⚠️ 没用 watch（正是开5 的缺口） |
| 学10 | 项目代码结构 | ✅ 12 个模块目录划分清晰；⚠️ 但 `load_config` ↔ `conn_balancer` 有**头文件级循环依赖**（靠前向声明打断） |
| 学11 | 模块交互流程 | ✅ 见本文第一节的 17 段链路 |
| 学12 | CMake 的使用 | ✅ `CMakeLists.txt` 有依赖查找、glob、三 target、包含目录、链接库；⚠️ **没有 `enable_testing()`/CTest、没有 install 规则、没有 presets**；**学12.3 要求"在多操作系统上练习构建 Windows/Linux/macOS 的 Demo"** —— 本项目**在 Windows 上根本编不过** |
| 学13 | Git 的使用 | ✅ 远程 `upstream`/`origin` 配置正确、有 feature 分支；⚠️ 见学5 |
| 学14 | Protobuf 序列化 | ✅ **学14.4「通过 vcpkg 集成 protobuf」做到了**；⚠️ **学14.5「单元测试，测试 protobuf 的序列化和反序列化能力」完全没有**（仓库里没有任何测试） |
| 学15 | 项目编译及启动 | ✅ 有 `rpc_build.sh` + README 运行说明；⚠️ README 里的路径 `./rpc-tutorial/build/...` 与仓库名不符；⚠️ 未知能否在**你的**环境下编过（见第三节） |

### 4.3 阶段二之后的「未来展望与拓展」

计划里的三条（更多优化项 / 拓展项 / 面试题准备）—— 原仓库**没有**对应内容。
但值得注意：**我们已经发现的这些断裂点（B1-B5、S1-S6），本身就是最好的"优化项"素材**。把 TCP 分帧、写回压、连接并发安全、负载均衡接线、ZK watch 这五件事补上，比新加功能更能体现水平。

---

## 五、逐个回应你原本的三个判断

> **你的原话 1**：「我感觉他那个项目只是完成了很多前期准备，一些核心的开发案是要完成的」

❌ **这个判断需要修正。**
**阶段二的 13 个开发单元，代码全部都在**，包括最难的两个大件：
- `network/`（~1400 行）：epoll/kqueue 事件循环、accept/read/close/错误处理、边缘触发、`TCP_NODELAY`
- `thread_pool/`（~1000 行）：优先级队列、背压、动态扩容、优雅关闭、统计

而且 `core/servers_main.cpp` 把「日志 → 配置 → 线程池 → 监听 socket → 事件循环 → 服务注册 → ZK 注册 → 信号处理 → 优雅关闭」**完整地串了起来**。这**不是**"只做了前期准备"，而是"主体骨架已经成型"。

正确的说法是：**每一层都通了，但每一层都没收尾。** 收尾缺的不是"核心开发"，而是**工程闭环**：测试、依赖锁定、协议健壮性（分帧/半包/写回压）、并发安全。

> **你的原话 2**：「核心的开发案是要完成的，但我不确定」

✅ **方向上对，程度要调整。**
- "有代码" ≠ "符合验收标准"。13 个单元里，**开4（负载均衡）和开5（ZK 节点管理）是典型的"代码在但没接到正确位置/是空壳"**：
  - 开4：三个均衡器写得没错，但**客户端根本没初始化策略** → 跑起来永远是随机。你在客户端打断点会看到 `"Load balancer not initialized"` 的警告。
  - 开5：能列节点，但**监听是空实现**（`global_watcher` 什么都不做）—— 而"节点管理"的验收标准正是"通过 C++ 代码获取 zookeeper 的节点信息"+"能够获取增加和删除情况"。**"增加和删除情况"这一半做不到**。
- **开8（加解密）是最需要警惕的一个**：代码能跑、加解密对称，但它是**自定义移位密码**，不是 AES，还有一个硬编码在源码里的主密钥。计划里"开8.3 注：也可以使用其他加解密方式"这句让它合规，但**简历上写"AES 加解密"会被问穿**。

> **你的原话 3**：「我没有跑那个测试的代码，也没去安装他们的项目环境，所以我没法测试」

✅ 这是事实，但补一个更关键的：**这个仓库里没有单元测试可以跑**。
`grep gtest|catch2|enable_testing|add_test` 全仓库零命中，没有 `tests/` 目录。唯一的"测试"是压测客户端 `stress_test_client` + `stress_test.sh`（测吞吐不测正确性），以及仓库根目录那个**不参与构建**的 `test.cpp`（结构体对齐练手文件）。

所以你想"跑一下他的测试来验收"这条路**本身就不存在**。要验收只能**自己写测试**。这恰好也是训练计划里要求但原仓库缺失的部分（学14.5、开6.1）。

---

## 六、如果你想真的把它跑起来 + 验收，该怎么走

### 阶段 A：先让它编过（预计踩 3 个坑）

| 步骤 | 具体做法 | 对应的坑 |
|---|---|---|
| 1 | **用 Linux**（WSL2 或云主机）。Windows 原生不行 | 平台限制 |
| 2 | 装 vcpkg，按 **protobuf 5.29.3** 装（否则 pb.h 的 `#error` 直接挡你） | 风险 1 |
| 3 | 装齐：`protobuf absl nlohmann-json spdlog zstd cryptopp zookeeper` | 学3 |
| 4 | 改 `rpc_build.sh` 里的 `VCPKG_ROOT`（默认 `/root/.vcpkg`）和 `PROTOC` 路径 | 写死路径 |
| 5 | 把 `create_socket.cpp` 的 9 处 `%d/%s` 改成 `{}`（如果编译报 unused arguments） | 风险 2 |
| 6 | **建议补一个 `vcpkg.json`** 把 7 个依赖版本锁住，让环境可复现 | M8 |
| 7 | 起一个 ZooKeeper（`zkServer.sh start`，默认 2181） | 强依赖 ZK |

### 阶段 B：跑通 happy path（验证"最小闭环成立"）

```bash
./rpc_build.sh
cd build && ./rpc_server          # 一个终端
cd build && ./rpc_client          # 另一个终端
```
预期：客户端打出 Sync call succeeded / 300 条 async 结果；服务端日志可见请求处理。
在 ZooKeeper 上 `ls /cookrpc/cookrpc_service` 应该能看到注册的临时节点。

### 阶段 C：写测试去**证伪**那些断裂点（这才是真正的验收）

不要只满足于"能跑通"。按下面的实验清单一个个打，打过才叫"闭环"：

| 实验 | 怎么做 | 预期（按我的静态分析） | 验证了哪条 |
|---|---|---|---|
| ① 大报文 | 请求体塞 100KB 以上字符串 | **可能失败**：跨 TCP 分段 → 解压失败 → 连接被关 | B1 半包 |
| ② 客户端并发 | 多线程各自 `Call()`，或去掉 `Call` 里的锁 | 串行（锁）；去掉锁后响应可能错配 | B4 |
| ③ 服务端单连接并发 | 一个客户端快速连发多条（不等待响应） | 第二条被吞（`read_buffer_.clear()`） | B1 粘包 |
| ④ 大响应 / 慢客户端 | 让服务端返回大 body，客户端读取前先 sleep | 响应丢失、客户端超时（无 EPOLLOUT） | B2 |
| ⑤ 负载均衡 | 在客户端打日志看有没有 `"load balancer not initialized"` | **必然出现**，恒为随机 | S1 |
| ⑥ 线程池核心线程 | 启动服务端后数线程数（`ls /proc/<pid>/task`） | 启动时 **0 个 worker** | S2 |
| ⑦ ZK 节点变更 | 手动 `create`/`delete` 一个节点，看客户端是否立刻感知 | 不会感知（无 watch），只在下次 `getServer` 拉取 | S4 |
| ⑧ 断开 ZK | `kill` 掉 ZooKeeper，看客户端行为 | `ensureZkConnection` 只重试 3×100ms → 报错退出 | 学9 / S4 |
| ⑨ Ctrl-C 优雅关闭 | 对服务端发 SIGINT | 会走 `atexit` 的 `GracefulShutdown`，但日志会打 `"Unexpected exit"` | M7 |
| ⑩ 压测 | `./stress_test.sh -c 20 -r 200` | 看 QPS/成功率；注意 `stress_test.sh` 的结论块变量未定义，**直接看 `stress_test_client` 自己的输出** | D 级 |

### 阶段 D：想达到"简历级/答辩级"，优先补这 5 件事

按「性价比」排序（改完就能理直气壮写进简历）：

1. **TCP 分帧 + 半包重组**（B1）—— 这是 RPC 框架的必修课，也是当前最致命的缺陷
2. **写回压 / EPOLLOUT + 写缓冲加锁**（B2 + B3）—— 并发正确性
3. **负载均衡接线修正**：把 `load_balance_strategy` 挪到客户端配置并真正 `initBalancer`（S1）+ `weight` 真的支持权重（S5）
4. **ZooKeeper watch 化**：注册 `zoo_get_children` 的 watcher，本地缓存 + 变更回调，去掉"每 RPC 一次 ZK 往返"（S4）
5. **补测试**：gtest + CTest，覆盖序列化（含 protobuf）、协议编解码边界、线程池、连接收发（补齐 学14.5 / 开6.1）

附加项（加分）：把自定义移位密码换成真 AES（或直接上 OpenSSL/Crypto++，反正 CMake 已经链了 Crypto++）、主密钥改从环境变量/配置读、`tasks_failed_` 与线程池计数修对、`cleanup()` 的静态守卫去掉。

---

## 七、哪些超出计划、哪些计划里有但没做

### 超出训练计划的东西（作者自己加的）

| 内容 | 说明 |
|---|---|
| `stress_test_client.cpp` + `stress_test.sh` | 完整压测工具链（QPS/成功率/延迟，支持按请求数或按时长两种模式）—— 计划里没有 |
| `docs/MASTER_KEY_GUIDE.md` | 337 行的密钥管理指南 —— 计划里没有，**且与代码不符**（M3） |
| `count_lines.py` | 代码行数统计工具 —— 计划里没有 |
| 线程池的优先级调度 / 背压 / 动态扩容 / 暂停恢复 / 统计 | 计划只要求"自己实现一个线程池"，作者做超了（虽然 `pause/resume` 自己承认项目里没用上） |
| 优雅关闭（信号 + 连接清理 + 线程池 drain + ZK cleanup） | 计划没有明确要求，作者做了 |
| 加密的"双重加密"设计（随机会话密钥 + 主密钥） | 计划只要求 AES 加解密，作者做了个自定义方案 |

### 计划里有、但仓库里找不到的

| 计划条目 | 情况 |
|---|---|
| **学12.3** 在多操作系统上练习构建 Windows / Linux / macOS 的 Demo | ❌ 项目**在 Windows 上编不过** |
| **学14.5** 单元测试，测试 protobuf 的序列化和反序列化能力 | ❌ 仓库**没有任何单元测试**，且 protobuf 路径**从未被调用** |
| **开6.1** 自己完成一个线程池的开发，**并进行测试** | ⚠️ 线程池本身做得好，但**没有测试** |
| **开4.1** 实现多种负载均衡器 | ⚠️ 三个类都有，但**实际只跑随机**；加权=轮询 |
| **开5.2** 通过 C++ 代码获取 zookeeper 的节点信息（含"增加和删除情况"） | ⚠️ "获取列表"做到了，"感知增删"**没有**（无 watch） |

---

## 八、给你的学习建议（结合他们的网课）

考虑到你的目标是**通过这个项目学 RPC + 写进简历**，而这个仓库是"骨架完整、收尾缺失"，建议这样用：

1. **不要把它当成"标准答案照抄"** —— 它有价值的地方是**目录结构、模块划分、协议设计、线程池实现**；它的坑正好是**你要学的重点**。
2. **按本文第一节的 17 段链路读代码**（配合 [[CookRPC架构与文件职责说明]] 的逐文件表），先建立全局图景。
3. **重点精读 3 个文件**：
   - `rpc_src/thread_pool/thread_pool.h` —— 队列/条件变量/背压/完美转发，是 C++ 并发的综合练习
   - `rpc_src/network/message_cycle.cpp` —— Reactor 模式的完整实现
   - `rpc_src/network/connection.cpp` —— **带着"它哪里错了"的问题去读**，这是收益最大的一个文件
4. **对着 5 个断裂点动手改**（第六节阶段 D），改完就是**你自己的项目亮点**，而且面试时你能讲清"为什么需要 TCP 分帧""为什么需要 EPOLLOUT""为什么写缓冲要加锁"——这些比"我实现了一个 RPC" 有说服力得多。
5. **不要写进简历的东西**：`AES 加解密`（实际是移位密码 + 硬编码密钥）、`加权轮询`（权重恒为 1）、`ZooKeeper 节点监听`（空实现）。先修好再写。

---

## 九、文档关系

| 文档 | 内容 |
|---|---|
| 本文 | 闭环判定、断裂点清单（带 file:line）、**训练计划 28 项对照**、上手与验收清单 |
| [[CookRPC架构与文件职责说明]] | 总体架构、协议字节布局、调用链路、**52 个文件的逐个职责说明**、构建组织、阅读顺序 |

> [!note] 审计声明
> 本文所有结论基于**静态代码精读**（52 个手写源文件全部读过 + 调用点 grep 交叉验证），**未编译、未运行、未修改任何文件**。
> 带 `file:line` 的为直接读取的代码事实；标注「推断」/「可能」的为未经运行验证的推理。
> 如需把某些结论钉死（尤其是能否编译、半包是否真的失败），必须按第六节阶段 A/B/C 在 Linux 上实测。
