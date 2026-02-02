# edge.ng

自托管 SSH 隧道内网穿透服务的介绍页。Astro 静态站点，部署在 Cloudflare Pages。

## 开发

```sh
npm install
npm run dev        # http://localhost:4321
```

## 发布

```sh
npm run deploy     # 构建并发布到 Cloudflare Pages（项目 edge-ng）
```

发布后生效于 https://edge-ng.pages.dev 及绑定的自定义域名。

## 隧道服务本体

服务端用一键脚本部署（本仓库 [scripts/sish-install.sh](scripts/sish-install.sh)，
同步发布于 [Gist](https://gist.github.com/harrisonwang/bcbfea9d71510ec300bdbfe9eab8f9bb)）：

```sh
curl -fsSL https://gist.githubusercontent.com/harrisonwang/bcbfea9d71510ec300bdbfe9eab8f9bb/raw/sish-install.sh \
  | sudo DOMAIN=example.com ACME_EMAIL=you@example.com CF_Token=xxx TAKEOVER_22=yes bash
```

环境变量、子命令（`takeover-22` / `confirm` / `status` / `uninstall`）与完整说明见脚本头部注释。
修改脚本后记得同步更新 Gist：`gh gist edit bcbfea9d71510ec300bdbfe9eab8f9bb -f sish-install.sh scripts/sish-install.sh`

## 目录结构

```text
src/
├── components/    Nav / Hero / Features / QuickStart / SelfHost / Footer
├── layouts/       Layout.astro
├── pages/         index.astro
└── styles/        global.css（设计令牌：纸面底色 + 赤陶橙）
scripts/
└── sish-install.sh   服务端一键安装脚本（Gist 的源文件）
```
