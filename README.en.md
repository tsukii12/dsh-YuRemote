[简体中文](README.md) · **English**

<img src="assets/brand/yuremote-wordmark.png" alt="YuRemote" width="96">

# YuRemote

Use DeepSeek Harness on another device without moving your work off the host. Open the web remote in a browser, or use the native Flutter app for iPhone, iPad and Android.

<img src="docs/screenshots/mobile-home.png" alt="YuRemote web home on a phone" width="280"> <img src="docs/screenshots/app-settings-about.png" alt="About YuRemote in the iOS app" width="280">

- **Web remote:** use dsh from a phone or computer, with a layout that adapts to narrow screens.
- **Mobile app:** continue conversations, stream replies and answer approvals; access workspaces and files supported by your host.
- **Your network:** connect directly on your LAN or use a relay you control. Sign in with a password or pair with a one-time QR code.

## Get started

1. [Install YuRemote on the dsh host](docs/GETTING-STARTED.md#install-on-the-host).
2. In dsh, open **Remote access → General** and set an access password.
3. Copy the address or scan the QR code under **Local network**. Use a browser or [install the mobile app](docs/APP.md).

[Documentation](docs/README.md#english) · [Public access](docs/DEPLOY-SERVER.md) · [Releases](https://github.com/tsukii12/dsh-YuRemote/releases) · [Changelog](CHANGELOG.md) · [Security policy](SECURITY.md)

**Server, plugin and relay: [MIT](LICENSE). Mobile app (`app/` and the dsh-Go-derived `packages/`): [AGPL-3.0](app/LICENSE).** The separate `dsh_portal` adapter also uses AGPL-3.0; see [package notices](packages/NOTICE). The web remote and installers are covered by MIT. YuRemote is not an official DeepSeek product.
