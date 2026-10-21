# usbipd-setup-for-wsl

Windows に接続した USB デバイスをダブルクリックひとつで WSL 2 に共有し、
必要なら USB Ethernet アダプタを WSL 内でジャンボフレーム(MTU 4000)付きで設定するスクリプト集です。

*English version: [README.md](README.md)*

---

## 目次

1. [このリポジトリでできること](#1-このリポジトリでできること)
2. [必要なもの](#2-必要なもの)
3. [初回のセットアップ](#3-初回のセットアップ)
4. [共有するデバイスを登録する](#4-共有するデバイスを登録する)
5. [実行する](#5-実行する)
6. [動作確認](#6-動作確認)
7. [日常的な使い方](#7-日常的な使い方)
8. [デバイスを Windows に戻す](#8-デバイスを-windows-に戻す)
9. [USB Ethernet とジャンボフレーム(任意)](#9-usb-ethernet-とジャンボフレーム任意)
10. [ファイル一覧](#10-ファイル一覧)
11. [トラブルシューティング](#11-トラブルシューティング)
12. [知っておくとよいこと](#12-知っておくとよいこと)
13. [ライセンス](#ライセンス)

---

## 1. このリポジトリでできること

WSL 2 は単体では USB デバイスを認識できません。オープンソースのツール
[usbipd-win](https://github.com/dorssel/usbipd-win) を使うと、USB/IP 経由で
Windows の USB デバイスを WSL に転送できます。ただし手作業で使うには、デバイスを
挿すたびに複数のコマンドを(一部は管理者権限で)実行する必要があります。

このリポジトリは、その一連の操作を 2 つのバッチファイルにまとめたものです。

| ダブルクリックするファイル | 動作 |
|---|---|
| `run.bat` | `devices.psd1` に登録されたデバイスのうち、今接続されているものを Windows 側で **bind**(共有)し、WSL に **attach** します。以降は自動 attach になるので、抜き差ししても WSL に接続されたままです。ASIX の USB Ethernet アダプタが含まれていれば、WSL 内で IP アドレスと(可能なら)MTU 4000 を設定します。 |
| `restore.bat` | 上記を元に戻します。デバイスを WSL から切り離し、Windows の通常ドライバに戻します。 |

想定している用途は、WSL 内の Linux ツールチェーンから組み込みターゲットを扱うための
デバッグプローブ(SEGGER J-Link、ST-Link)と USB Ethernet アダプタの利用です。

### 全体の流れ

```
Windows                                   WSL 2 (Ubuntu)
───────────────────────────────────       ──────────────────────────────────────
run.bat
 ├─ ensure-service.ps1   usbipd の Windows サービスが止まっていれば起動
 ├─ check-bind.ps1       接続中のデバイスがすべて共有済みか確認
 ├─ bind.ps1  (管理者)   usbipd bind   → デバイスが "Shared" になる
 ├─ attach.ps1 (一般)    usbipd attach → WSL にデバイスが見える ───────────► lsusb に表示される
 └─ wsl -u root bash setup_interface_for_wsl.sh ─────────────────────────► udev ルール(一般ユーザーで USB を使えるように)
                                                                          ジャンボフレーム対応ドライバ(このカーネル用のビルドがあれば)
                                                                          enx* インターフェースに IP アドレスと MTU を設定
```

---

## 2. 必要なもの

**ハードウェア**

- WSL 2 が入った Windows PC(WSL 1 では動作しません)。
- WSL で使いたい USB デバイス。初期状態で登録されているのは次の 3 つです。
  - SEGGER J-Link(`1366:0101`)
  - NUCLEO ボード上の ST-Link(`0483:374e`)
  - ASIX AX88179 USB 3.0 Gigabit Ethernet アダプタ(`0b95:1790`)

  他のデバイスも追加できます。[4 章](#4-共有するデバイスを登録する)を参照してください。

**ソフトウェア**

- Windows 10(ビルド 19041 以降)または Windows 11。
- WSL 2 のディストリビューション。スクリプトは Ubuntu 向けに書かれており、`apt` を使います。
- Windows PC の管理者権限。bind に必要で、UAC のダイアログが出ます。attach には不要です。
- usbipd-win **4.0 以降**(次章でインストールします)。

**USB Ethernet アダプタでジャンボフレームを使いたい場合のみ**

- WSL からのインターネット接続と数 GB の空きディスク。パッチ済みドライバを WSL
  カーネルのバージョンごとに 1 回ビルドするために必要です。詳しくは
  [9 章](#9-usb-ethernet-とジャンボフレーム任意)。これを省略してもアダプタ自体は
  通常の MTU 1500 で動作します。

---

## 3. 初回のセットアップ

### 3.1 Windows に usbipd-win をインストールする

PowerShell を開いて次を実行します。

```powershell
winget install usbipd
```

または <https://github.com/dorssel/usbipd-win/releases> からインストーラを
ダウンロードしてください。

インストール後、`usbipd` が `PATH` に入るようにターミナルを開き直してから確認します。

```powershell
usbipd --version
```

インストーラは `usbipd` という名前の Windows サービスも登録します。
止まっていればスクリプトが自動で起動します。

### 3.2 WSL 2 が動くことを確認する

```powershell
wsl --status
wsl -l -v
```

使うディストリビューションの `VERSION` が `2` になっている必要があります。
まだディストリビューションがなければ次でインストールできます。

```powershell
wsl --install -d Ubuntu
```

WSL 内で手動でインストールするものはありません。`setup_interface_for_wsl.sh` の
初回実行時に、`usbutils`(`lsusb` 用)と `net-tools`(`ifconfig` 用)が無ければ
`apt` で入れます。自分で入れておきたい場合は次のとおりです。

```bash
sudo apt update
sudo apt install usbutils net-tools
```

> usbipd-win 4.x では、WSL 側の `usbip` クライアントツール(`linux-tools-generic`)は
> **不要**です。手動でデバッグするときにだけ役立ちます。

### 3.3 このリポジトリを取得する

**C ドライブ上**の任意の場所、たとえば `C:\tools\usbipd-setup-for-wsl` に clone
またはコピーします。

```powershell
git clone https://github.com/tatsuyai713/usbipd-setup-for-wsl.git C:\tools\usbipd-setup-for-wsl
```

C ドライブである理由は、`run.bat` がシェルスクリプトを呼ぶときに自分の Windows パスの
`C:/` を `/mnt/c/` に置き換えて WSL のパスに変換しているためです。別のドライブに置く
場合は、`run.bat` の 3 行目の `set SCRIPT_DIR` を書き換えてください(例: `D:/` を `/mnt/d/` に)。

**改行コードに注意してください。** `setup_interface_for_wsl.sh`、`build_ko.sh`、
`ko/` 以下のファイルは WSL 内の bash で実行されるため、Windows 形式(CRLF)の改行で
保存されていると分かりにくい構文エラーで失敗します。リポジトリの `.gitattributes` が
`*.sh` と `*.patch` を LF に強制するので、通常の `git clone` であれば問題ありません。
VS Code でスクリプトを編集した場合は、右下のステータスバーが `CRLF` ではなく `LF`
になっていることを確認してください(クリックで変更できます)。

---

## 4. 共有するデバイスを登録する

すべてのスクリプトは `devices.psd1` という 1 つのファイルを読みます。
名前と VID:PID の組を並べた PowerShell のリストです。

```powershell
@(
    @{ Name = "J-Link";          VidPid = "1366:0101" },
    @{ Name = "ST-Link-NUCLEO";  VidPid = "0483:374e" },
    @{ Name = "ASIX AX88179";    VidPid = "0b95:1790" }
)
```

- `Name` はメッセージ表示にだけ使われます。好きな名前で構いません。
- `VidPid` は USB のベンダー ID と プロダクト ID を小文字の 16 進数でコロン区切りにした
  ものです。USB ポートではなくこの ID で照合するので、どのポートに挿しても構いません。

デバイスの ID は、接続した状態で PowerShell から次を実行すると分かります。

```powershell
usbipd list
```

出力例:

```
Connected:
BUSID  VID:PID    DEVICE                                                        STATE
1-3    1366:0101  J-Link driver                                                 Not shared
2-1    0b95:1790  ASIX AX88179 USB 3.0 to Gigabit Ethernet Adapter              Not shared
```

`VID:PID` 列の値を `devices.psd1` に書き写します。ファイルに登録されていても接続
されていないデバイスは単にスキップされるので、持っているデバイスを全部書いておいて
問題ありません。

> **udev ルールはこのファイルから自動生成されます。** WSL 内では、udev ルールで許可されて
> いない USB デバイスを一般ユーザーは開けません。`setup_interface_for_wsl.sh` は
> `devices.psd1` にあるベンダー ID ごとにルールを書き出すので、ここに追加したデバイスは
> 次に `run.bat` を実行したときから `sudo` 無しで使えるようになります。ルールはベンダー ID
> だけで照合するため、同じベンダーの別製品(たとえば他の ST-Link のバリエーション)も
> 対象になります。生成処理は 1 行ずつ読むので、上の例のように 1 エントリを 1 行で
> 書いてください。

### USB Ethernet アダプタのネットワーク設定(任意)

ASIX アダプタを使う場合は、`setup_interface_for_wsl.sh` の先頭の値を環境に合わせて
変更します。

```bash
IP_ADDR="192.168.2.100"     # WSL 内でアダプタに付ける IP アドレス
NETMASK="255.255.255.0"
MTU=4000                    # ジャンボフレーム対応ドライバがあるときだけ有効。9 章参照
```

これらは `run.bat` を実行するたびに設定されます。WSL を再起動すると消えます。

---

## 5. 実行する

1. USB デバイスを接続します。
2. **WSL を起動し**、ターミナルを開いたままにします(たとえばスタートメニューから
   「Ubuntu」を開く)。`usbipd attach --wsl` は WSL が動いている必要があります。
3. `run.bat` をダブルクリックします。

コンソールウィンドウが開き、以下のステップが順に進みます。各ステップで何が起きるか、
何が表示されるかを説明します。

### Step 0: Ensure USBIPD Service

`usbipd` の Windows サービスが動いているか確認します。通常は起動時に始まりますが、
`restore.bat` や手動の `usbipd` コマンドのあと止まったままのことがあります。
止まっていれば **UAC が 1 回**表示され、サービスが起動されます。

### Step 1: Check bind status / Bind (Admin)

「bind」とは、デバイスを usbipd に渡すよう Windows に指示することです。デバイスの通常の
Windows ドライバがスタブドライバに置き換わります。これには管理者権限が必要です。

- まず `devices.psd1` にある接続中のデバイスをすべて確認します。全部が既に `Shared` か
  `Attached` なら bind はスキップされ、**UAC は表示されません**。
- そうでなければ UAC が表示されます。許可すると管理者権限の PowerShell ウィンドウが
  もう 1 つ開き、必要なデバイスを bind(`usbipd bind --force`)して `Bind completed.`
  と表示し、Enter 待ちになります。閉じて先に進んでください。

接続されていないデバイスは `SKIP ... Not connected` と表示されます。

### Step 2: Attach (User)

次のメッセージで一時停止します。

```
Please start WSL before proceeding.
Press Enter after WSL is running...
```

WSL のターミナルが開いていることを確認して Enter を押します。少し待ったあと、
各デバイスが次のコマンドで attach されます。

```
usbipd attach --wsl --auto-attach --hardware-id <VID:PID>
```

`--auto-attach` により、デバイスごとに小さな `usbipd` プロセスが非表示で動き続けます。
以降、デバイスを抜き差ししても、WSL を再起動しても、自動で WSL に再 attach されます。
これらのプロセスはログオフするか、`restore.bat` を実行するか、自分で終了させるまで
残ります。

続けてスクリプトは WSL 内で `lsusb` を実行し、動作中の `usbipd` プロセス数を表示して
確認します。

### Step 3: Configure Network in WSL

`setup_interface_for_wsl.sh` が WSL 内で root として実行され、次を行います。

1. 実行中カーネル用のジャンボフレーム対応ドライバが `ko/` 以下にあれば
   インストールします([9 章](#9-usb-ethernet-とジャンボフレーム任意))。
   無ければ警告を表示し、標準ドライバのままにします。
2. `usbutils` と `net-tools` が無ければインストールします。
3. `devices.psd1` から `/etc/udev/rules.d/99-usbipd-devices.rules` を生成し、登録された
   すべてのデバイス(USB ノードと、あればそのシリアルポート)を一般ユーザーが開けるように
   してから udev を再読み込みします。このファイルは実行のたびに書き直されるので、
   手で編集しないでください。
4. `enx*` という名前のネットワークインターフェースを探します(USB Ethernet アダプタは
   MAC アドレスに基づくこの名前になります)。見つからなければここで終了します。
   ASIX アダプタを使っていなければこれが正常です。
5. MTU を設定し、IP アドレスを付与し、インターフェースを up にします。
6. 要求した MTU が受け付けられなかった場合、その理由と、ジャンボフレーム対応ドライバを
   ビルドするためのコマンドを表示します。

### Result

最後に `usbipd list`(Windows 側)と `lsusb`(WSL 側)の出力を表示してキー入力を待ちます。

---

## 6. 動作確認

Windows 側:

```powershell
usbipd list
```

デバイスが `Attached` になっているはずです。

WSL 側:

```bash
lsusb                      # デバイスが一覧に出る
ip addr show               # ASIX アダプタ使用時: enx* インターフェースに設定した IP アドレスが付いている
ip -d link show | grep mtu # mtu 4000 ならジャンボフレーム対応ドライバが有効
```

デバッグプローブの場合は、**root ではない**シェルからベンダーのツール(`JLinkExe` や
`st-info --probe` など)を試してください。`sudo` を付けたときだけ動くなら、udev ルールが
無いか再読み込みされていません。[トラブルシューティング](#11-トラブルシューティング)を
参照してください。

---

## 7. 日常的な使い方

- **Windows を再起動したあと:** `run.bat` をもう一度実行します。bind は usbipd が
  覚えているので管理者ステップはスキップされますが、自動 attach プロセスと WSL 内の
  ネットワーク設定は消えているので作り直す必要があります。
- **WSL を再起動したあと(`wsl --shutdown`):** `--auto-attach` のおかげでデバイスは
  自動で戻ってきますが、Ethernet アダプタの IP アドレスと MTU は戻りません。
  `run.bat` を再実行するか、WSL 内で次を実行します。

  ```bash
  sudo bash /mnt/c/tools/usbipd-setup-for-wsl/setup_interface_for_wsl.sh
  ```

- **デバイスを抜き差ししたあと:** 何もしなくても自動で再 attach されます。Ethernet
  アダプタを抜き差しした場合は、上のスクリプトを再実行して IP アドレスを戻してください。
- **新しいデバイスを追加する:** `devices.psd1` に追記し、接続して `run.bat` を実行します。
  新しいデバイスの bind のために UAC が表示されます。
- **WSL に attach されている間、そのデバイスは Windows から使えません。** これは USB/IP
  の仕組み上そうなります。Windows で使いたいときは `restore.bat` を実行してください。

`run.bat` は何度実行しても安全です。bind 済みのデバイスはスキップされ、
自動 attach プロセスが新たに起動されます。

---

## 8. デバイスを Windows に戻す

`run.bat` は `bind --force` と `--auto-attach` を使うため、デバイスを抜いても WSL 専用の
ままです。Windows に戻すには次のようにします。

1. `restore.bat` をダブルクリックします。

**Step 1: Detach (User)** では、attach 中のすべてのデバイスを WSL から切り離します。

**Step 2: Unbind (Admin)** では UAC が表示され、その後:

- `usbipd` の自動 attach バックグラウンドプロセスをすべて停止します。デバイスを挿し直した
  瞬間に WSL に戻ってしまわないようにするためです。
- `devices.psd1` の各デバイスを unbind し、元の Windows ドライバに戻します。
- `usbipd unbind --all` を実行し、共有されたまま残っているものを掃除します。

終わると `usbipd list` でデバイスが `Not shared` になり、Windows で普通に使えます。
後で `run.bat` を実行すれば、最初から bind と attach をやり直します。

`restore.bat` は WSL 側には触れません。udev ルールとジャンボフレーム対応ドライバは
インストールされたまま残りますが、害はありません。標準の Ethernet ドライバに戻す方法は
[9.5 節](#95-確認と復元)を参照してください。

---

## 9. USB Ethernet とジャンボフレーム(任意)

ASIX AX88179 アダプタを使わない場合、または MTU 1500 で十分な場合、この章は読み飛ばして
構いません。

### 9.1 問題

WSL 2 カーネルに同梱されている `ax88179_178a` ドライバは、1500 を超える MTU を受け付け
ません。ハードウェアは 4088 まで対応しており、ドライバもそう宣言しているのですが、
汎用の `usbnet` 層が、ドライバが `FLAG_NOMAXMTU` フラグを立てていない限り上限を 1500 に
丸めてしまいます。upstream のドライバはこのフラグを立てていません。

### 9.2 対策

このリポジトリには、そのフラグを 1 つ追加して再ビルドした `ax88179_178a.ko` が含まれて
います(3 行の変更です。`ko/patches/apply-jumbo-patch.sh` を参照)。これにより
`ip link set dev enx... mtu 4000` が成功するようになります。

カーネルモジュールは、ビルド対象にしたカーネルそのものにしかロードできません。カーネルは
モジュールが使う各シンボルのチェックサム(CRC)を比較し、1 つでも違えばモジュールを拒否
します。`wsl --update` でカーネルが時々変わるため、カーネルのバージョンごとにビルドを
1 つずつ保持しています。

```
ko/
├── ko_lib.sh                        # ヘルパー: status / check / apply / restore
├── patches/apply-jumbo-patch.sh     # ビルド時に適用するソース変更
└── <カーネルリリース>/              # `uname -r` ごとに 1 フォルダ。例: 6.18.40.1-microsoft-standard-WSL2
    ├── ax88179_178a.ko              # パッチ済みモジュール
    ├── BUILD_INFO.txt               # 使用したソースのタグ、config、コンパイラ、CRC 検証の結果
    └── jumbo.patch                  # 実際に適用した diff
```

> フォルダ `6.18.35.2-microsoft-standard-WSL2+`(末尾の `+` に注意)は、ローカルで改変した
> カーネル向けのビルドで、Microsoft が配布しているカーネルにはロードできません。
> 参考用に残しているだけです。

### 9.3 自動で行われること

`run.bat` が Step 3 に達するたびに、`setup_interface_for_wsl.sh` が
`ko/$(uname -r)/ax88179_178a.ko` を探します。

- **見つかり、CRC が実行中カーネルと一致する場合:** モジュールを
  `/lib/modules/$(uname -r)/kernel/drivers/net/usb/` にコピーし、`depmod` を実行し、
  ドライバをアンロードして再ロードするので、その場で有効になります。標準モジュールは
  初回に `/var/lib/usbipd-setup-wsl/pristine/` にバックアップされます。
- **見つからない場合:** 警告を表示し、標準ドライバのまま(MTU 1500)にします。
- **見つかったが CRC が違う場合:** 絶対にインストールしません。再ビルドを促します。

自分のカーネルバージョンが `ko/` のフォルダのどれかと一致していれば、それ以上やることは
ありません。

### 9.4 新しいカーネル向けにドライバをビルドする

WSL 内でカーネルのバージョンを確認します。

```bash
uname -r
```

`ko/` に一致するフォルダが無ければビルドします。**WSL 内で、root ではなく通常のユーザー**
として実行してください。

```bash
cd /mnt/c/tools/usbipd-setup-for-wsl      # リポジトリを置いた場所
./build_ko.sh
```

初回は時間がかかります(カーネルソースのダウンロードとモジュールのコンパイルで、回線と
CPU により 5〜15 分程度)。`~/src` 以下におよそ 3 GB のディスクが必要です。
スクリプトは次を行います。

1. ビルドツールが無ければ `apt` でインストールします
   (`build-essential flex bison bc libssl-dev libelf-dev git kmod dwarves`)。
   `sudo` のパスワードを聞かれることがあります。
2. [microsoft/WSL2-Linux-Kernel](https://github.com/microsoft/WSL2-Linux-Kernel) から
   `uname -r` に一致するタグを `~/src/WSL2-Linux-Kernel` に取得します(shallow clone。
   既存のチェックアウトがあれば、別の git worktree 経由で再利用し、元のツリーは変更しません)。
3. 実行中カーネルの設定を `/proc/config.gz` から取得します。
4. ジャンボフレームのパッチを適用します。
5. `drivers/net/usb` のモジュールをビルドします。
6. モジュールがカーネルから import する全シンボルの CRC をカーネルソースから計算し、
   実行中カーネル自身のモジュールが持つ CRC と比較します。1 つでも違えばスクリプトは停止し、
   何も保存しません。これがモジュールが確実にロードできることの保証になります。
7. デバッグ情報を strip し、`ax88179_178a.ko`、`BUILD_INFO.txt`、`jumbo.patch` を
   `ko/<カーネルリリース>/` に保存します。

終わったら `run.bat` を再実行する(または WSL 内で `sudo ko/ko_lib.sh apply` を実行する)と
モジュールがインストールされます。git を使っているなら、同じカーネルの他のマシンでも使える
ように新しいフォルダをコミットしてください。

主なオプション(`./build_ko.sh --help` で全部見られます):

| オプション | 意味 |
|---|---|
| `--install` | ビルド直後にモジュールをインストールする(sudo を求められます) |
| `--clean` | 終了後にビルド用 worktree を削除してディスクを空ける |
| `--no-fetch` | ネットワークを一切使わない。ソースが無ければ失敗する |
| `--ref TAG` | `uname -r` に一致するものではなく別のカーネルタグをビルドする |
| `--config FILE` | `/proc/config.gz` の代わりにこのカーネル config を使う |
| `--src DIR`, `--build-dir DIR` | カーネルソースとビルドツリーの置き場所(既定: `~/src/WSL2-Linux-Kernel`、`~/src/wsl-ko-build`) |
| `-j N` | 並列コンパイル数(既定: 全 CPU) |

### 9.5 確認と復元

```bash
ko/ko_lib.sh status                               # どのビルドがあるか、どれがインストール済みか、現在の MTU
ko/ko_lib.sh check ko/<release>/ax88179_178a.ko   # モジュールの CRC を実行中カーネルと比較
sudo ko/ko_lib.sh apply                           # 実行中カーネル用のビルドをインストール
sudo ko/ko_lib.sh restore                         # Microsoft 標準のモジュールに戻す
```

`restore` は `apply` が取ったバックアップを使います。このカーネルで `apply` を実行した
ことがなければ、戻すものはありません。

---

## 10. ファイル一覧

| ファイル | 実行場所 | 役割 |
|---|---|---|
| `run.bat` | Windows | メインの入口。Step 0〜3 を順に実行する。 |
| `restore.bat` | Windows | すべてを detach・unbind してデバイスを Windows に戻す。 |
| `devices.psd1` | Windows と WSL | 共有する USB デバイスの一覧。udev ルールの生成元でもある。**ここを編集する。** |
| `ensure-service.ps1` | Windows | `usbipd` Windows サービスが止まっていれば起動する(必要なら UAC)。 |
| `check-bind.ps1` | Windows | 接続中の全デバイスが bind 済みなら終了コード 0、そうでなければ 1。`run.bat` が UAC を省略するために使う。 |
| `bind.ps1` | Windows(管理者) | 必要なデバイスを `usbipd bind --force` する。 |
| `attach.ps1` | Windows | 接続中の各デバイスを `usbipd attach --wsl --auto-attach` し、`lsusb` を表示する。 |
| `detach.ps1` | Windows | attach 中の各デバイスを `usbipd detach` する。 |
| `unbind.ps1` | Windows(管理者) | 自動 attach プロセスを終了し、各デバイスを `usbipd unbind` し、最後に `unbind --all`。 |
| `setup_interface_for_wsl.sh` | WSL(root) | パッケージをインストールし、`devices.psd1` から udev ルールを生成し、あればジャンボフレーム対応ドライバを入れ、`enx*` インターフェースを設定する。**先頭の IP/MTU を編集する。** |
| `build_ko.sh` | WSL(一般ユーザー) | 実行中カーネル用のジャンボフレーム対応ドライバを `ko/<release>/` にビルドする。 |
| `ko/ko_lib.sh` | WSL | 上の 2 つのスクリプトが使うライブラリ。コマンドラインツールでもある(`status`、`check`、`apply`、`restore`)。 |
| `ko/patches/apply-jumbo-patch.sh` | WSL | ビルド時に適用するソース変更。 |
| `ko/<release>/` | WSL | カーネルバージョンごとのビルド済みドライバとビルド記録。 |
| `.gitattributes` | git | `*.sh` と `*.patch` の改行コードを LF に強制する。 |

---

## 11. トラブルシューティング

| 症状 | 確認すること |
|---|---|
| `run.bat` のウィンドウがすぐ閉じる。 | コマンドプロンプトを開き、フォルダに `cd` してから `run.bat` を実行するとエラーが残ります。最も多い原因は `usbipd` が見つからないことです。usbipd-win のインストール後にターミナルを開き直すか、再インストールしてください。 |
| `usbipd` が認識されない。 | usbipd-win が未インストールか、インストール前に開いたターミナルを使っています。[3.1](#31-windows-に-usbipd-win-をインストールする)を参照。 |
| `WARNING: 'usbipd' service not found`。 | usbipd-win が未インストールか、古いバージョン(3.x)です。4.0 以降を入れてください。 |
| 以前 bind したのに UAC が出る。 | デバイスを別の USB ポートに挿してバス ID が変わったか、Windows Update でドライバが置き換わりました。許可してください。bind はすぐ終わります。 |
| `usbipd list` で `Shared` のまま `Attached` にならない。 | Step 2 で Enter を押したときに WSL が起動していませんでした。WSL のターミナルを開いて `run.bat` を再実行してください。 |
| WSL の `lsusb` にデバイスが出ない。 | WSL 内で `dmesg \| tail -20` を見てドライバのメッセージを確認します。`usbipd` の自動 attach プロセスが動いているかも確認してください(タスクマネージャー、または PowerShell で `Get-Process usbipd`)。 |
| WSL でデバイスを使うのに `sudo` が必要。 | udev ルールが適用されていません。`sudo udevadm control --reload-rules && sudo udevadm trigger` を実行し、デバイスを抜き差ししてください。`devices.psd1` に無いデバイスなら、そこに追加して `run.bat` を再実行してください。 |
| `setup_interface_for_wsl.sh` が `syntax error` や `$'\r': command not found` で失敗する。 | ファイルが CRLF 改行になっています。LF で保存し直すか(VS Code: ステータスバーの `CRLF` をクリック)、WSL 内で `sed -i 's/\r$//' setup_interface_for_wsl.sh` を実行してください。 |
| `No enx* interface found`。 | ASIX アダプタが接続されていない、attach されていない、またはカーネルにドライバがありません。`lsusb` に `0b95:1790` があるか、`dmesg \| grep ax88179` を確認してください。 |
| `WARNING: Requested MTU 4000 but interface reports 1500`。 | このカーネル用のジャンボフレーム対応ドライバがありません。WSL 内で `./build_ko.sh` を実行し([9.4](#94-新しいカーネル向けにドライバをビルドする))、`run.bat` を再実行してください。`ko/ko_lib.sh status` で何が保存されているか分かります。 |
| `build_ko.sh` が `no source found for kernel ...` と言う。 | WSL からインターネットに出られないか、Microsoft がまだこのカーネルバージョンにタグを付けていません。<https://github.com/microsoft/WSL2-Linux-Kernel/tags> を確認し、別名のタグがあれば `--ref` で指定してください。 |
| `build_ko.sh` が `CRC mismatch` と言う。 | ソースのタグか config が実行中カーネルと一致していません。`--ref` や `--config` を誤って渡していないか確認してください。`--force` は理解している場合以外使わないでください。一致しないモジュールはどのみちカーネルに拒否されます。 |
| `build_ko.sh` が `do not run as root` と言う。 | `sudo ./build_ko.sh` ではなく、通常ユーザーのシェルから実行してください。必要なところでは自分で `sudo` を求めます。 |
| WSL を再起動したら IP アドレスや MTU が消えた。 | 仕様です。設定は永続化されません。`run.bat` かシェルスクリプトを再実行してください([7 章](#7-日常的な使い方)参照)。 |
| `restore.bat` のあと `run.bat` を実行したら、Windows には見えるが WSL に出ない。 | unbind のあとドライバの切り替えが終わるまで数秒待ってから `run.bat` を実行してください。 |

---

## 12. 知っておくとよいこと

- **`--force` 付きの bind** は Windows にスタブドライバをインストールします。unbind する
  (`restore.bat`)まで、再起動してもデバイスは Windows で使えません。
- **udev ルールは `MODE="0666"`** なので、WSL ディストリビューション内のすべてのユーザーが
  `devices.psd1` に登録したデバイスを開けます。1 人で使う開発 PC なら問題ありませんが、そうでない場合は
  ルールを絞ってください。
- attach されたデバイスを持てる **WSL ディストリビューションは同時に 1 つ**だけです。
  `usbipd attach --wsl` は既定のディストリビューションを対象にします。
- **ビルド記録。** 各 `ko/<release>/BUILD_INFO.txt` には、カーネルソースのタグとコミット、
  config の取得元、コンパイラのバージョン、CRC 検証の結果が書かれているので、保存されて
  いるモジュールが何者か正確に分かります。
- **Windows 側には usbipd-win 以外何もインストールしません。** `restore.bat` を実行した
  あとリポジトリのフォルダを削除すれば、Windows には何も残りません。WSL 側には udev
  ルールのファイル、インストールしたドライバ、`/var/lib/usbipd-setup-wsl/` 以下の
  バックアップが残りますが、手で削除できます。

---

## ライセンス

MIT License です。[LICENSE](LICENSE) を参照してください。

`ko/` 以下のパッチ済み `ax88179_178a.ko` は Linux カーネルのソースからビルドしたもので、
スクリプトの MIT ライセンスではなくカーネル自身のライセンス(GPL-2.0)に従います。
