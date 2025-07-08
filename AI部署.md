### 				基于 华为Kunpeng-920（Arm64）+ 昇腾Atlas 300i duo *8 部署 DeepSeek-R1-32B

#### 一、前置检查

1. 查看当前系统环境和架构

   ```shell
   uname -m && cat /etc/*release
   ```

2. 确认昇腾AI处理器已经安装妥当

   ```shell
   lspci | grep 'Processing accelerators'
   ```

3. 确认Python版本

```shell
python --version
```

| **软件**     | **版本**                                     |
| ------------ | -------------------------------------------- |
| **操作系统** | **openEuler20.03/22.03, Ubuntu 20.04/22.04** |
| **Python**   | **3.7, 3.8, 3.9, 3.10, 3.11.4**              |

> 避免依赖冲突，建议虚拟出Python环境来为后面驱动安装做准备，这里使用conda进行来实现
>
> 1、**下载和安装方法**：
>
> **X86_64架构**：
>
> ```shell
> mkdir -p ~/miniconda3
> wget https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh -O ~/miniconda3/miniconda.sh
> bash ~/miniconda3/miniconda.sh -b -u -p ~/miniconda3
> rm ~/miniconda3/miniconda.sh
> ```
>
> **Arm64架构**：
>
> ```shell
> mkdir -p ~/miniconda3
> wget https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-aarch64.sh -O ~/miniconda3/miniconda.sh
> bash ~/miniconda3/miniconda.sh -b -u -p ~/miniconda3
> rm ~/miniconda3/miniconda.sh
> ```
>
> **国内环境可能对Python源不友好，切换为国内镜像源（这里使用中科大的镜像源）**
>
> ```shell
> conda config --add channels https://mirrors.ustc.edu.cn/anaconda/pkgs/main/
> conda config --add channels https://mirrors.ustc.edu.cn/anaconda/pkgs/free/
> conda config --add channels https://mirrors.ustc.edu.cn/anaconda/cloud/conda-forge/
> conda config --add channels https://mirrors.ustc.edu.cn/anaconda/cloud/msys2/
> conda config --add channels https://mirrors.ustc.edu.cn/anaconda/cloud/bioconda/
> conda config --add channels https://mirrors.ustc.edu.cn/anaconda/cloud/menpo/
> conda config --set show_channel_urls yes
> ```
>
> 2、**创建Python3.10环境**：
>
> ```shell
> conda create -n dlmode(自定义) python=3.10
> ```
>
> 3、**进入创建好的Python3.10环境**
>
> ```shell
> conda activate dlmode
> ```

#### 二、安装驱动

[昇腾官方安装指引](https://www.hiascend.com/document/detail/zh/CANNCommunityEdition/82RC1alpha001/softwareinst/instg/instg_0001.html?Mode=PmIns&OS=Ubuntu&Software=cannToolKit)

 **安装说明**

- 首次安装场景：硬件设备刚出厂时未安装驱动，或者硬件设备前期安装过驱动和固件但是当前已卸载，上述场景属于首次安装场景，需按照**“驱动 > 固件”**的顺序安装驱动和固件。

- 覆盖安装场景：硬件设备前期安装过驱动和固件且未卸载，当前要再次安装驱动和固件，此场景属于覆盖安装场景，需按照

  “固件>驱动”的顺序安装。

  用户可使用如下命令查询当前环境是否安装驱动，若返回驱动相关信息说明已安装。

  ```
  npu-smi info
  ```

##### 1、安装必要的依赖

```shell
Ubuntu:
sudo apt-get install -y gcc make dkms net-tools python3 python3-dev python3-pip 

OpenEuler/Centos:
sudo yum install -y gcc make dkms net-tools python3 python3-devel python3-pip
```

##### 2、创建驱动运行用户

因为安装昇腾驱动和固件需要`HwHiAiUser`，所以第一次安装的时候需要进行创建该用户

```shell
sudo groupadd HwHiAiUsersudo useradd -g HwHiAiUser -d /home/HwHiAiUser -m HwHiAiUser -s /bin/bashsudo usermod -aG HwHiAiUser $USER
```

##### 3、下载驱动

```shell
驱动:
wget "https://ascend-repo.obs.cn-east-2.myhuaweicloud.com/Ascend HDK/Ascend HDK 25.0.RC1.1/Ascend-hdk-310p-npu-driver_25.0.rc1.1_linux-aarch64.run"
固件：
wget "https://ascend-repo.obs.cn-east-2.myhuaweicloud.com/Ascend HDK/Ascend HDK 25.0.RC1.1/Ascend-hdk-310p-npu-firmware_7.7.0.1.231.run"
CANN:
wget "https://ascend-repo.obs.cn-east-2.myhuaweicloud.com/CANN/CANN 8.1.RC1/Ascend-cann-toolkit_8.1.RC1_linux-aarch64.run"
wget "https://ascend-repo.obs.cn-east-2.myhuaweicloud.com/CANN/CANN 8.1.RC1/Ascend-cann-kernels-310p_8.1.RC1_linux-aarch64.run"
```

##### 4、驱动安装

######   4.1添加授权可执行权限

```shell
chmod +x Ascend-hdk-310p-npu-driver_25.0.rc1.1_linux-aarch64.run 
chmod +x Ascend-hdk-310p-npu-firmware_7.7.0.1.231.run
chmod +x Ascend-cann-toolkit_8.1.RC1_linux-aarch64.run
chmod +x Ascend-cann-kernels-310p_8.1.RC1_linux-aarch64.run
```

######   4.2校验软件包一致性和完整性

```shell
./Ascend-hdk-310p-npu-driver_25.0.rc1.1_linux-aarch64.run  --check
./Ascend-hdk-310p-npu-firmware_7.7.0.1.231.run --check
```

  出现如下回显信息，表示软件包校验成功。

```shell
Verifying archive integrity...  100%   SHA256 checksums are OK. All good.
```

######   4.3安装驱动和固件，软件包默认安装路径为“/usr/local/Ascend”。

执行如下命令安装驱动。

```shell
./Ascend-hdk-310p-npu-driver_25.0.rc1.1_linux-aarch64.run --full --install-for-all
```

若系统出现如下关键回显信息，则表示驱动安装成功。

```shell
Driver package installed successfully!
```

执行如下命令安装固件。

```shell
./Ascend-hdk-310p-npu-firmware_7.7.0.1.231.run --full
```

若系统出现如下关键回显信息，表示固件安装成功。

```shell
Firmware package installed successfully! Reboot now or after driver installation for the installation/upgrade to take effect
```

根据系统提示信息决定是否重启系统，若需要重启，请执行以下命令；否则，请跳过此步骤。

```shell
reboot
```

执行如下命令查看驱动加载是否成功

```shell
npu-smi info
```

![img]([npustat](https://github.com/xenoscccd/Demo/blob/main/png/npustat.png))

##### 5、安装CANN

> **配置最大线程数（可选）**
>
> 训练场景下，OS的最大线程数可能不满足训练要求，以root用户执行以下命令修改最大线程数为无限制。
>
> 1. 配置环境变量，修改线程数为无限制，打开“/etc/profile”文件。
>
>    ```SHELL
>    vi /etc/profile
>    ```
>
> 2. 在文件的最后添加如下内容后保存退出。
>
>    ```shell
>    ulimit -u unlimited
>    ```
>
> 3. 执行如下命令使环境变量生效。
>
>    ```SHELL
>    source /etc/profile
>    ```

###### 5.1安装依赖

以下步骤中命令会安装最新版本或指定版本的依赖，关于Python第三方库、glibc版本要求请参考[依赖列表](https://www.hiascend.com/document/detail/zh/CANNCommunityEdition/82RC1alpha001/softwareinst/instg/instg_0045.html#ZH-CN_TOPIC_0000002302136525)。

1. （如果已经在前期已经安装且准备好了conda环境，这一步略过。）以安装用户登录服务器，执行如下命令安装依赖软件（如果使用root用户安装依赖，请将命令中的sudo删除）。

   Debian系列：

   ```shell
   sudo apt-get install -y python3 python3-pip
   ```

   CANN支持Python3.7.*x*至3.11.4版本，若安装失败、版本不满足或者未包含动态库libpython3.*x*.so请参考[编译安装Python](https://www.hiascend.com/document/detail/zh/CANNCommunityEdition/82RC1alpha001/softwareinst/instg/instg_0061.html#ZH-CN_TOPIC_0000002302103485)操作。

2. 执行如下命令安装运行时依赖的Python第三方库：

   ```shell
   pip3 install attrs cython numpy==1.24.0 decorator sympy cffi pyyaml pathlib2 psutil protobuf==3.20 scipy requests absl-py 
   ```

   若源不可以用，请参考[配置pip源](https://www.hiascend.com/document/detail/zh/CANNCommunityEdition/82RC1alpha001/softwareinst/instg/instg_0061.html#ZH-CN_TOPIC_0000002302103485__zh-cn_topic_0000002256343898_zh-cn_topic_0000001574665046_li128072047428)，完成后再执行安装命令。需注意Python3.7.*x*时推荐安装numpy 1.21.6版本。

###### 5.2安装Toolkit开发套件包

​	校验软件包一致性和完整性

```shell
./Ascend-cann-toolkit_8.1.RC1_linux-aarch64.run --check
```

出现如下回显信息，表示软件包校验成功。

```shell
Verifying archive integrity...  100%   SHA256 checksums are OK. All good.
```

安装软件包（安装命令支持--install-path=*<path>*等参数，具体使用方式请参见[参数说明](https://www.hiascend.com/document/detail/zh/CANNCommunityEdition/82RC1alpha001/softwareinst/instg/instg_0043.html#ZH-CN_TOPIC_0000002267423636)）。

```shell
./Ascend-cann-toolkit_8.1.RC1_linux-aarch64.run --install
```

执行以上命令会显示[华为企业业务最终用户许可协议（EULA）](https://e.huawei.com/cn/about/eula)的条款和条件，请输入**Y**或**y**同意协议，继续安装流程。

安装完成后，若显示如下信息，则说明软件安装成功：

```shell
xxx install success
```

*xxx*表示安装的实际软件包名。

如果用户未指定安装路径，则软件会安装到默认路径下，默认安装路径如下。root用户：“/usr/local/Ascend”，非root用户：“*${HOME}*/Ascend”，*${HOME}*为当前用户目录。

1. 配置环境变量，当前以root用户安装后的默认路径为例，请用户根据set_env.sh的实际路径执行如下命令。

   ```shell
   source /usr/local/Ascend/ascend-toolkit/set_env.sh
   ```

   上述环境变量配置只在当前窗口生效，用户可以按需将以上命令写入环境变量配置文件（如.bashrc文件）。

2. 安装后检查。执行如下命令查询CANN版本信息，查询结果与安装软件包的版本一致时，则验证安装成功。

   1. 进入软件包安装信息文件目录，请用户根据实际安装路径替换。

      表示CPU架构（aarch64或x86_64）。

      ```shell
      cd /usr/local/Ascend/ascend-toolkit/latest/arm64-linux/
      ```

   2. 执行命令，查看version字段提供的版本信息。

      ```shell
      cat ascend_toolkit_install.info
      ```

###### 5.3安装Kernels算子包

校验软件包一致性和完整性

```shell
./Ascend-cann-kernels-310p_8.1.RC1_linux-aarch64.run --check
```

出现如下回显信息，表示软件包校验成功。

```shell
Verifying archive integrity...  100%   SHA256 checksums are OK. All good.
```

安装除静态库之外的其他文件，请执行如下命令：

```shell
./Ascend-cann-kernels-310p_8.1.RC1_linux-aarch64.run --install
```

执行以上命令会显示[华为企业业务最终用户许可协议（EULA）](https://e.huawei.com/cn/about/eula)的条款和条件，请输入**Y**或**y**同意协议，继续安装流程。

安装完成后，若显示如下信息，则说明软件安装成功：

```shell
xxx install success
```

**xxx**表示安装的实际软件包名。

安装后检查。执行如下命令查询软件版本信息，查询结果与安装软件包的版本一致时，则验证安装成功。

```shell
#进入软件包安装信息文件目录，请用户根据实际安装路径替换。
cd /usr/local/Ascend/ascend-toolkit/latest/opp_kernel
```

```shell
#执行以下命令，查看version_dir字段提供的版本信息。
cat version.info
```

#### 三、Docker安装

1、使用docker官方脚本一键安装

```shell
 #下载脚本到本地
 curl -fsSL https://get.docker.com -o get-docker.sh
 #安装docker，使用阿里云源
 bash get-docker.sh --mirror Aliyun
```

2、检查是否安装完成

```shell
#查看docker版本
docker version

#返回的结果例：
Client: Docker Engine - Community
 Version:           28.0.4
 API version:       1.48
 Go version:        go1.23.7
 Git commit:        b8034c0
 Built:             Tue Mar 25 15:07:33 2025
 OS/Arch:           linux/arm64
 Context:           default

Server: Docker Engine - Community
 Engine:
  Version:          28.0.4
  API version:      1.48 (minimum version 1.24)
  Go version:       go1.23.7
  Git commit:       6430e49
  Built:            Tue Mar 25 15:07:33 2025
  OS/Arch:          linux/arm64
  Experimental:     false
 containerd:
  Version:          1.7.27
  GitCommit:        05044ec0a9a75232cad458027ca83437aae3f4da
 runc:
  Version:          1.2.5
  GitCommit:        v1.2.5-0-g59923ef
 docker-init:
  Version:          0.19.0
  GitCommit:        de40ad0
```

#### 四、配置镜像和模型并启动

##### 1.下载大模型

可以在[魔塔社区](https://modelscope.cn/)上找到相应的模型。例如我这里使用的是  **DeepSeek-R1-Distill-Qwen-32B** 

下载模型可以通过多种方式下载，这里使用 ModelScope SDK 来进行下载模型使用。[ModelScope SDK使用指引](https://modelscope.cn/docs/%E6%A8%A1%E5%9E%8B%E7%9A%84%E4%B8%8B%E8%BD%BD)

```shell
#在下载前，请先通过如下命令安装ModelScope
pip install modelscope
#下载完整模型库到指定路径
modelscope download --model deepseek-ai/DeepSeek-R1-Distill-Qwen-32B README.md --local_dir /data2/models/DeepSeek-R1-Distill-Qwen-32B

## --local_dir 后对应要把模型库存放的路径
```

执行完上述命令下载完镜像后，**因为300I-DUO这张卡只能使用torch_dtype类型为float16，所以需要修改大模型目录下的config.json文件，找到`torch_dtype` 改为 `float16`**

```shell
# root@admin1:/data2/models/DeepSeek-R1-Distill-Qwen-32B# cat config.json 

{
  "architectures": [
    "Qwen2ForCausalLM"
  ],
  "attention_dropout": 0.0,
  "bos_token_id": 151643,
  "eos_token_id": 151643,
  "hidden_act": "silu",
  "hidden_size": 5120,
  "initializer_range": 0.02,
  "intermediate_size": 27648,
  "max_position_embeddings": 131072,
  "max_window_layers": 64,
  "model_type": "qwen2",
  "num_attention_heads": 40,
  "num_hidden_layers": 64,
  "num_key_value_heads": 8,
  "rms_norm_eps": 1e-05,
  "rope_theta": 1000000.0,
  "sliding_window": 131072,
  "tie_word_embeddings": false,
  "torch_dtype": "float16",
  "transformers_version": "4.43.1",
  "use_cache": true,
  "use_sliding_window": false,
  "vocab_size": 152064
}
```



##### 2.mindie镜像准备

[镜像下载地址（需要申请授权）](https://www.hiascend.com/developer/ascendhub/detail/af85b724a7e5469ebd7ea13c3439d48f)
**# 需要下载自己对应的NPU卡型号，当前（2025/7/8）只有800I和300I-DUO两个型号的镜像。我当前环境的卡是300I-DUO。**

![img](https://www.hikunpeng.com/doc_center/source/zh/kunpengrag/bestpractice/figure/zh-cn_image_0000002362016553.png)

###### 2.1 启动容器

```shell
#这里使用compose文件来进行启动

name: 32b
services:
    mindie1.0:
        stdin_open: true  # 允许标准输入保持打开状态
        tty: true  # 为容器分配一个伪终端
        network_mode: host  # 使用主机的网络模式
        shm_size: 500g  # 设置共享内存大小为500GB
        privileged: true  # 以特权模式运行容器
        container_name: mindie32b  # 容器的名称为mindie32b
        devices:
            - /dev/davinci_manager  # 挂载davinci_manager设备
            - /dev/hisi_hdc  # 挂载hisi_hdc设备
            - /dev/devmm_svm  # 挂载devmm_svm设备
        environment:
            - ASCEND_RUNTIME_OPTIONS=NODRV  # 设置环境变量ASCEND_RUNTIME_OPTIONS为NODRV
        volumes:
            - /usr/local/Ascend/driver:/usr/local/Ascend/driver:ro  # 只读挂载Ascend驱动目录
            - /usr/local/sbin:/usr/local/sbin:ro  # 只读挂载sbin目录
            - /data2/models/DeepSeek-R1-Distill-Qwen-32B:/data/deepseek:ro  # 只读挂载模型数据目录
        image: mindie1.0  # 使用的镜像为mindie1.0，我这里使用下载到本地的镜像名，请以实际为准。
        command: bash  # 容器启动时执行bash命令

```

###### 2.2 进入容器进行修改相关操作

```shell
#进入容器，mindie32b为容器名称，请根据实际情况替换。
docker exec -it mindie32b bash

```

```shell
#修改配置文件
vim /usr/local/Ascend/mindie/latest/mindie-service/conf/config.json
```

首先附上[Mindie server参数](https://www.hiascend.com/document/detail/zh/mindie/100/mindieservice/servicedev/mindie_service0285.html)

![img](https://www.hikunpeng.com/doc_center/source/zh/kunpengrag/bestpractice/figure/zh-cn_image_0000002362016561.png)

**注意：300I-DUO这张卡当前只能使用4卡并行处理，所以这里应该是0,1,2,3,4,5,6,7。图片引用第三方，请以实际为准。**

![img](https://i-blog.csdnimg.cn/img_convert/2aac3cdb53041a712d753b79a280231c.png)

###### 2.3 启动模型

```shell
# 进入服务目录
cd /usr/local/Ascend/mindie/latest/mindie-service/
# 配置环境变量
source set_env.sh
# 后台启动服务
nohup ./bin/mindieservice_daemon > output.log 2>&1 &
# 如需要查看启动日志 
tail -f output.log
```

打印如下信息说明启动成功。

```shell
Daemon start success!
```

###### 2.4 发起测试请求

```shell 
#新启一个终端，执行执行命令请求
curl -H "Accept: application/json" -H "Content-type: application/json" \
-X POST -d '{
    "model": "ds-r1-32b", 
    "messages": [{
        "role": "user",
        "content": "你是谁？"
    }],
    "stream": false,
    "presence_penalty": 1.03,
    "frequency_penalty": 1.0,
    "repetition_penalty": 1.0,
    "temperature": 0.5,
    "top_p": 0.95,
    "top_k": 10,
    "seed": null,
    "stop": ["stop1", "stop2"],
    "stop_token_ids": [2, 13],
    "include_stop_str_in_output": false,
    "skip_special_tokens": true,
    "ignore_eos": false,
    "max_tokens": 20
}' http://**.**.**.**:1025/v1/chat/completions 
```

返回结果例：

```shell
{"id":"endpoint_common_642","object":"chat.completion","created":1751962541,"model":"ds-r1-32b","choices":[{"index":0,"message":{"role":"assistant","content":"您好！我是由中国的深度求索（DeepSeek）公司开发的智能助手DeepSeek-R","tool_calls":null},"finish_reason":"length"}],"usage":{"prompt_tokens":8,"completion_tokens":20,"total_tokens":28},"prefill_time":130,"decode_time_arr":[80,79,77,86,78,81,78,78,77,79,84,80,78,79,75,79,80,79,81]}
```

