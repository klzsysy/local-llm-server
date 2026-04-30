# Local LLM Server Tools

- [llm-api-benchmark](llm-api-benchmark.html) 参考vllm和sglang编写的API性能测试可视化工具，可以直接本地浏览器打开，或者访问[在线版本](https://llm-test.ifaii.com)
- fan-control 基于GPU/GPU温度通过IPMI控制主板风扇的脚本，配置service实现自动化运行，当前在超微 H12SSL 主板上稳定运行，其他超微型号如H11SSL、H13SSL也许可以支持，使用需要修改脚本顶部的IPMI信息。