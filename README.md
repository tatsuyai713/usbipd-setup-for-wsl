# usbipd-setup-for-wsl

Scripts that share USB devices from Windows to WSL 2 with a double-click, and
optionally configure a USB Ethernet adapter inside WSL with jumbo frames (MTU 4000).

*日本語版は [README.ja.md](README.ja.md) をご覧ください。*

---

## Table of contents

- [usbipd-setup-for-wsl](#usbipd-setup-for-wsl)
  - [Table of contents](#table-of-contents)
  - [1. What this does](#1-what-this-does)
    - [How the pieces fit together](#how-the-pieces-fit-together)
  - [2. What you need](#2-what-you-need)
  - [3. One-time setup](#3-one-time-setup)
    - [3.1 Install usbipd-win on Windows](#31-install-usbipd-win-on-windows)
    - [3.2 Make sure WSL 2 is working](#32-make-sure-wsl-2-is-working)
    - [3.3 Get this repository](#33-get-this-repository)
  - [4. Tell the scripts which devices to share](#4-tell-the-scripts-which-devices-to-share)
    - [Network settings for the USB Ethernet adapter (optional)](#network-settings-for-the-usb-ethernet-adapter-optional)
  - [5. Run it](#5-run-it)
    - [Step 0: Ensure USBIPD Service](#step-0-ensure-usbipd-service)
    - [Step 1: Check bind status / Bind (Admin)](#step-1-check-bind-status--bind-admin)
    - [Step 2: Attach (User)](#step-2-attach-user)
    - [Step 3: Configure Network in WSL](#step-3-configure-network-in-wsl)
    - [Result](#result)
  - [6. Check that it worked](#6-check-that-it-worked)
  - [7. Everyday use](#7-everyday-use)
  - [8. Give the devices back to Windows](#8-give-the-devices-back-to-windows)
  - [9. USB Ethernet and jumbo frames (optional)](#9-usb-ethernet-and-jumbo-frames-optional)
    - [9.1 The problem](#91-the-problem)
    - [9.2 The fix](#92-the-fix)
    - [9.3 What happens automatically](#93-what-happens-automatically)
    - [9.4 Building the driver for a new kernel](#94-building-the-driver-for-a-new-kernel)
    - [9.5 Checking and restoring](#95-checking-and-restoring)
  - [10. File reference](#10-file-reference)
  - [11. Troubleshooting](#11-troubleshooting)
  - [12. Good to know](#12-good-to-know)
  - [License](#license)

---

## 1. What this does

WSL 2 cannot see USB devices on its own. The open-source tool
[usbipd-win](https://github.com/dorssel/usbipd-win) solves that by forwarding
a USB device from Windows into WSL over USB/IP. Using it by hand means running
several commands, some of them as administrator, every time you plug a device in.

This repository wraps all of that into two batch files:

| You double-click | What happens |
|---|---|
| `run.bat` | Every device listed in `devices.psd1` that is currently plugged in is **bound** on Windows and **attached** to WSL. Attachment is automatic from then on, so unplugging and re-plugging the device keeps it in WSL. If an ASIX USB Ethernet adapter is among the devices, it is given an IP address and (if possible) an MTU of 4000 inside WSL. |
| `restore.bat` | Undoes the above. Devices are detached from WSL and get their normal Windows drivers back. |

Typical use case: debug probes (SEGGER J-Link, ST-Link) and a USB Ethernet adapter
for talking to an embedded target from a Linux toolchain inside WSL.

### How the pieces fit together

```
Windows                                   WSL 2 (Ubuntu)
───────────────────────────────────       ──────────────────────────────────────
run.bat
 ├─ ensure-service.ps1   start the usbipd Windows service if it is stopped
 ├─ check-bind.ps1       are all plugged-in devices already shared?
 ├─ bind.ps1  (admin)    usbipd bind   → device is "Shared"
 ├─ attach.ps1 (user)    usbipd attach → device appears in WSL ──────────► lsusb shows it
 └─ wsl -u root bash setup_interface_for_wsl.sh ─────────────────────────► udev rules (non-root USB access)
                                                                          jumbo-frame driver (if a build exists for this kernel)
                                                                          IP address + MTU on the enx* interface
```

---

## 2. What you need

**Hardware**

- A Windows PC with WSL 2 installed (WSL 1 does not work).
- The USB devices you want to use in WSL. Out of the box the scripts know about:
  - SEGGER J-Link (`1366:0101`)
  - ST-Link on a NUCLEO board (`0483:374e`)
  - ASIX AX88179 USB 3.0 Gigabit Ethernet adapter (`0b95:1790`)

  Any other device can be added, see [section 4](#4-tell-the-scripts-which-devices-to-share).

**Software**

- Windows 10 (build 19041 or later) or Windows 11.
- A WSL 2 distribution. The scripts were written for Ubuntu and use `apt`.
- Administrator rights on the Windows PC. Binding a device needs them; you will
  see a UAC prompt. Attaching does not.
- usbipd-win **4.0 or newer** (installed in the next section).

**Only if you want jumbo frames on the USB Ethernet adapter**

- Internet access from WSL and a few GB of free disk space, once per WSL kernel
  version, to build the patched driver. Details in [section 9](#9-usb-ethernet-and-jumbo-frames-optional).
  If you skip this the adapter still works, just with the normal MTU of 1500.

---

## 3. One-time setup

### 3.1 Install usbipd-win on Windows

Open PowerShell and run:

```powershell
winget install usbipd
```

Or download the installer from
<https://github.com/dorssel/usbipd-win/releases>.

Close and reopen your terminal afterwards so that `usbipd` is on the `PATH`, then check:

```powershell
usbipd --version
```

The installer also registers a Windows service named `usbipd`. The scripts start
it for you if it is not running.

### 3.2 Make sure WSL 2 is working

```powershell
wsl --status
wsl -l -v
```

Your distribution must show `VERSION 2`. If you do not have a distribution yet:

```powershell
wsl --install -d Ubuntu
```

Nothing has to be installed inside WSL by hand. The first run of
`setup_interface_for_wsl.sh` installs `usbutils` (for `lsusb`) and `net-tools`
(for `ifconfig`) with `apt` if they are missing. If you prefer to do it yourself:

```bash
sudo apt update
sudo apt install usbutils net-tools
```

> The `usbip` client tools (`linux-tools-generic`) are **not** required inside WSL
> with usbipd-win 4.x. They are only useful for manual debugging.

### 3.3 Get this repository

Clone or copy it somewhere **on the C: drive**, for example `C:\tools\usbipd-setup-for-wsl`.

```powershell
git clone https://github.com/tatsuyai713/usbipd-setup-for-wsl.git C:\tools\usbipd-setup-for-wsl
```

Why the C: drive? `run.bat` converts its own Windows path to a WSL path by
replacing `C:/` with `/mnt/c/` when it calls the shell script. If you keep the
repository on another drive, edit the third `set SCRIPT_DIR` line in `run.bat`
accordingly (for example `D:/` to `/mnt/d/`).

**Line endings matter.** `setup_interface_for_wsl.sh`, `build_ko.sh` and the files
under `ko/` are run by bash inside WSL and fail with confusing syntax errors if
they are saved with Windows (CRLF) line endings. The repository's `.gitattributes`
forces LF for `*.sh` and `*.patch`, so a normal `git clone` is fine. If you edit a
script in VS Code, check that the status bar in the bottom right says `LF`, not
`CRLF` (click it to change).

---

## 4. Tell the scripts which devices to share

All scripts read one file, `devices.psd1`. It is a PowerShell list of
name/VID:PID pairs:

```powershell
@(
    @{ Name = "J-Link";          VidPid = "1366:0101" },
    @{ Name = "ST-Link-NUCLEO";  VidPid = "0483:374e" },
    @{ Name = "ASIX AX88179";    VidPid = "0b95:1790" }
)
```

- `Name` is only used in messages. Pick anything you like.
- `VidPid` is the USB vendor and product ID, in hexadecimal, lower case,
  separated by a colon. Devices are matched by this ID, not by the USB port, so
  it does not matter where you plug them in.

To find the ID of a device, plug it in and run in PowerShell:

```powershell
usbipd list
```

Example output:

```
Connected:
BUSID  VID:PID    DEVICE                                                        STATE
1-3    1366:0101  J-Link driver                                                 Not shared
2-1    0b95:1790  ASIX AX88179 USB 3.0 to Gigabit Ethernet Adapter              Not shared
```

Copy the `VID:PID` column into `devices.psd1`. Devices that are listed in the
file but not plugged in are simply skipped, so it is fine to list everything
you own.

> **udev rules are generated from this file.** Inside WSL, normal users may only open
> a USB device if a udev rule allows it. `setup_interface_for_wsl.sh` writes one rule
> set per vendor ID found in `devices.psd1`, so any device you add here becomes
> usable without `sudo` the next time `run.bat` runs. Rules match on the vendor ID
> only, so sibling products of the same vendor (for example other ST-Link variants)
> are covered as well. Keep each entry on one line, as in the example above; the
> generator reads the file line by line.

### Network settings for the USB Ethernet adapter (optional)

If you use the ASIX adapter, open `setup_interface_for_wsl.sh` and adjust the
first lines:

```bash
IP_ADDR="192.168.0.100"     # address given to the adapter inside WSL
NETMASK="255.255.255.0"
MTU=4000                    # only takes effect with the jumbo-frame driver, see section 9
```

These settings are applied each time `run.bat` runs. They are not persistent
across a WSL restart.

---

## 5. Run it

1. Plug in your USB devices.
2. **Start WSL** and keep a terminal window open (for example open "Ubuntu" from
   the Start menu). `usbipd attach --wsl` needs a running WSL instance.
3. Double-click `run.bat`.

A console window opens and walks through these steps. Here is what each one does
and what you will see.

### Step 0: Ensure USBIPD Service

Checks that the `usbipd` Windows service is running. It is normally started at
boot, but `restore.bat` or a manual `usbipd` command can leave it stopped. If it
is stopped you get **one UAC prompt** and the service is started.

### Step 1: Check bind status / Bind (Admin)

"Binding" tells Windows to hand a device over to usbipd. It replaces the device's
normal Windows driver with a stub driver, and it requires administrator rights.

- First the script checks every plugged-in device from `devices.psd1`. If all of
  them are already `Shared` or `Attached`, binding is skipped and **no UAC
  prompt appears**.
- Otherwise a UAC prompt appears. Accept it. A second PowerShell window opens as
  administrator, binds each device that needs it (`usbipd bind --force`), prints
  `Bind completed.` and waits for you to press Enter. Close it and continue.

Devices that are not plugged in are reported as `SKIP ... Not connected`.

### Step 2: Attach (User)

The window pauses with:

```
Please start WSL before proceeding.
Press Enter after WSL is running...
```

Make sure a WSL terminal is open, then press Enter. After a short wait each
device is attached with

```
usbipd attach --wsl --auto-attach --hardware-id <VID:PID>
```

`--auto-attach` keeps a small hidden `usbipd` process running per device. From
now on the device is re-attached to WSL automatically whenever it is unplugged
and plugged back in, or whenever WSL is restarted. These processes live until you
log off, run `restore.bat`, or kill them yourself.

The script then runs `lsusb` inside WSL and shows how many `usbipd` processes are
running as a sanity check.

### Step 3: Configure Network in WSL

`setup_interface_for_wsl.sh` runs inside WSL as root and does the following:

1. Installs the jumbo-frame driver for the running kernel if a build for it
   exists under `ko/` ([section 9](#9-usb-ethernet-and-jumbo-frames-optional)).
   If not, it prints a warning and keeps the stock driver.
2. Installs `usbutils` and `net-tools` if missing.
3. Generates `/etc/udev/rules.d/99-usbipd-devices.rules` from `devices.psd1` so
   that normal users can open every listed device (USB node and, if present, its
   serial port), then reloads udev. Do not edit that file by hand; it is rewritten
   on every run.
4. Looks for a network interface named `enx*` (USB Ethernet adapters get such a
   name, derived from their MAC address). If none is found the step ends here,
   which is normal when you do not use the ASIX adapter.
5. Sets the MTU, assigns the IP address and brings the interface up.
6. If the interface did not accept the requested MTU, prints the reason and the
   command to build the jumbo-frame driver.

### Result

Finally the window prints the output of `usbipd list` (Windows side) and
`lsusb` (WSL side) and waits for a key press.

---

## 6. Check that it worked

On Windows:

```powershell
usbipd list
```

Your devices should show `Attached`.

Inside WSL:

```bash
lsusb                      # your devices should be listed
ip addr show               # with the ASIX adapter: an enx* interface with your IP address
ip -d link show | grep mtu # mtu 4000 means the jumbo-frame driver is active
```

For a debug probe, try the vendor's own tool, for example `JLinkExe` or
`st-info --probe`, from a **non-root** shell. If that works only with `sudo`,
the udev rule is missing or was not reloaded, see [Troubleshooting](#11-troubleshooting).

---

## 7. Everyday use

- **After rebooting Windows:** run `run.bat` again. Binding is remembered by
  usbipd, so the admin step is skipped, but the auto-attach processes and the
  network settings inside WSL are gone and have to be recreated.
- **After restarting WSL (`wsl --shutdown`):** the devices come back by
  themselves thanks to `--auto-attach`, but the IP address and MTU of the
  Ethernet adapter do not. Either run `run.bat` again or, inside WSL:

  ```bash
  sudo bash /mnt/c/tools/usbipd-setup-for-wsl/setup_interface_for_wsl.sh
  ```

- **After unplugging and re-plugging a device:** nothing to do, it is re-attached
  automatically. If the Ethernet adapter was re-plugged, re-run the script above
  to restore its IP address.
- **Adding a new device:** add it to `devices.psd1`, plug it in, run `run.bat`.
  You will get a UAC prompt for binding the new device.
- **While a device is attached to WSL it is not usable on Windows.** This is how
  USB/IP works. Run `restore.bat` when you need it on Windows again.

Running `run.bat` more than once is safe. Already-bound devices are skipped and
new auto-attach processes are started.

---

## 8. Give the devices back to Windows

Because `run.bat` uses `bind --force` and `--auto-attach`, the devices stay
dedicated to WSL even after you unplug them. To return them to Windows:

1. Double-click `restore.bat`.

**Step 1: Detach (User)** detaches every attached device from WSL.

**Step 2: Unbind (Admin)** shows a UAC prompt, then:

- stops all `usbipd` auto-attach background processes, so that re-plugging a
  device does not immediately send it back to WSL,
- unbinds each device from `devices.psd1`, which restores its original Windows
  driver,
- runs `usbipd unbind --all` to clean up anything that was left shared.

Afterwards `usbipd list` shows the devices as `Not shared` and they work normally
on Windows. Running `run.bat` later binds and attaches them again from scratch.

`restore.bat` does not touch the WSL side. The udev rules and the jumbo-frame
driver stay installed, which is harmless. To put the stock Ethernet driver back
see [section 9.5](#95-checking-and-restoring).

---

## 9. USB Ethernet and jumbo frames (optional)

Skip this section if you do not use the ASIX AX88179 adapter, or if an MTU of
1500 is fine for you.

### 9.1 The problem

The `ax88179_178a` driver that ships with the WSL 2 kernel refuses any MTU above
1500. The hardware supports up to 4088, and the driver even declares that, but
the generic `usbnet` layer clamps the maximum to 1500 unless the driver sets the
flag `FLAG_NOMAXMTU`. The upstream driver does not set it.

### 9.2 The fix

This repository carries a rebuilt `ax88179_178a.ko` with that one flag added
(see `ko/patches/apply-jumbo-patch.sh` for the three-line change). With it,
`ip link set dev enx... mtu 4000` succeeds.

A kernel module only loads into the exact kernel it was built for. The kernel
compares a checksum (CRC) of every symbol the module uses and rejects the module
if any of them differ. Because `wsl --update` changes the kernel from time to
time, one build is kept per kernel version:

```
ko/
├── ko_lib.sh                        # helper: status / check / apply / restore
├── patches/apply-jumbo-patch.sh     # the source change applied at build time
└── <kernel release>/                # one folder per `uname -r`, e.g. 6.18.40.1-microsoft-standard-WSL2
    ├── ax88179_178a.ko              # the patched module
    ├── BUILD_INFO.txt               # which source tag, config and compiler were used, and the CRC check result
    └── jumbo.patch                  # the exact diff that was applied
```

> The folder `6.18.35.2-microsoft-standard-WSL2+` (note the `+`) is a build for a
> locally modified kernel and does not load on any kernel shipped by Microsoft.
> It is kept for reference only.

### 9.3 What happens automatically

Every time `run.bat` reaches Step 3, `setup_interface_for_wsl.sh` looks for
`ko/$(uname -r)/ax88179_178a.ko`:

- **Found and CRCs match the running kernel:** the module is copied to
  `/lib/modules/$(uname -r)/kernel/drivers/net/usb/`, `depmod` is run, and the
  driver is unloaded and reloaded so the change takes effect at once. The stock
  module is backed up to `/var/lib/usbipd-setup-wsl/pristine/` the first time.
- **Not found:** a warning is printed and the stock driver stays (MTU 1500).
- **Found but CRCs differ:** the module is never installed. You will be told to rebuild.

If your kernel version matches one of the folders in `ko/`, there is nothing more
to do.

### 9.4 Building the driver for a new kernel

Find your kernel version inside WSL:

```bash
uname -r
```

If there is no matching folder under `ko/`, build one. Run this **inside WSL, as
your normal user, not as root**:

```bash
cd /mnt/c/tools/usbipd-setup-for-wsl      # wherever you put the repository
./build_ko.sh
```

The first run takes a while (downloading the kernel source and compiling the
module, typically 5 to 15 minutes depending on your connection and CPU). It needs
roughly 3 GB of disk space under `~/src`. The script:

1. Installs the build tools with `apt` if they are missing
   (`build-essential flex bison bc libssl-dev libelf-dev git kmod dwarves`).
   You may be asked for your `sudo` password.
2. Fetches the tag of [microsoft/WSL2-Linux-Kernel](https://github.com/microsoft/WSL2-Linux-Kernel)
   that matches `uname -r` into `~/src/WSL2-Linux-Kernel` (shallow clone; an
   existing checkout is reused through a separate git worktree and never modified).
3. Takes the running kernel's configuration from `/proc/config.gz`.
4. Applies the jumbo-frame patch.
5. Builds the `drivers/net/usb` modules.
6. Computes the CRC of every symbol the module imports from the kernel source and
   compares it with the CRCs the running kernel's own modules carry. If anything
   differs, the script stops and saves nothing. This is the guarantee that the
   module will load.
7. Strips debug info and saves `ax88179_178a.ko`, `BUILD_INFO.txt` and
   `jumbo.patch` into `ko/<kernel release>/`.

When it finishes, run `run.bat` again (or `sudo ko/ko_lib.sh apply` inside WSL)
to install the module. If you use git, commit the new folder so that other
machines with the same kernel get it too.

Useful options (`./build_ko.sh --help` lists them all):

| Option | Meaning |
|---|---|
| `--install` | install the module right after building (asks for sudo) |
| `--clean` | delete the build worktree afterwards to free disk space |
| `--no-fetch` | never use the network; fail if the source is not already present |
| `--ref TAG` | build another kernel tag than the one matching `uname -r` |
| `--config FILE` | use this kernel config instead of `/proc/config.gz` |
| `--src DIR`, `--build-dir DIR` | where to keep the kernel source and the build trees (defaults: `~/src/WSL2-Linux-Kernel`, `~/src/wsl-ko-build`) |
| `-j N` | number of parallel compile jobs (default: all CPUs) |

### 9.5 Checking and restoring

```bash
ko/ko_lib.sh status                               # which builds exist, which one is installed, current MTU
ko/ko_lib.sh check ko/<release>/ax88179_178a.ko   # compare a module's CRCs with the running kernel
sudo ko/ko_lib.sh apply                           # install the build for the running kernel
sudo ko/ko_lib.sh restore                         # put the stock Microsoft module back
```

`restore` uses the backup made by `apply`. If you never ran `apply` on this
kernel there is nothing to restore.

---

## 10. File reference

| File | Runs on | Purpose |
|---|---|---|
| `run.bat` | Windows | Main entry point. Runs Steps 0 to 3 in order. |
| `restore.bat` | Windows | Detaches and unbinds everything, returning the devices to Windows. |
| `devices.psd1` | Windows and WSL | The list of USB devices to share. Also the source of the udev rules. **Edit this.** |
| `ensure-service.ps1` | Windows | Starts the `usbipd` Windows service if it is stopped (UAC if needed). |
| `check-bind.ps1` | Windows | Exit code 0 if every plugged-in device is already bound, 1 otherwise. Lets `run.bat` skip the UAC prompt. |
| `bind.ps1` | Windows (admin) | `usbipd bind --force` for each device that needs it. |
| `attach.ps1` | Windows | `usbipd attach --wsl --auto-attach` for each plugged-in device, then shows `lsusb`. |
| `detach.ps1` | Windows | `usbipd detach` for each attached device. |
| `unbind.ps1` | Windows (admin) | Kills auto-attach processes, `usbipd unbind` for each device, then `unbind --all`. |
| `setup_interface_for_wsl.sh` | WSL (root) | Installs packages, generates udev rules from `devices.psd1`, installs the jumbo-frame driver if available, configures the `enx*` interface. **Edit the IP/MTU at the top.** |
| `build_ko.sh` | WSL (user) | Builds the jumbo-frame driver for the running kernel into `ko/<release>/`. |
| `ko/ko_lib.sh` | WSL | Library used by the two scripts above; also a command-line tool (`status`, `check`, `apply`, `restore`). |
| `ko/patches/apply-jumbo-patch.sh` | WSL | The source modification applied during the build. |
| `ko/<release>/` | WSL | Prebuilt driver plus build record for one kernel version. |
| `.gitattributes` | git | Forces LF line endings for `*.sh` and `*.patch`. |

---

## 11. Troubleshooting

| Symptom | What to check |
|---|---|
| The `run.bat` window closes immediately. | Open a Command Prompt, `cd` to the folder and run `run.bat` from there so the error stays visible. The most common cause is `usbipd` not being found: reopen the terminal after installing usbipd-win, or reinstall it. |
| `usbipd` is not recognized. | usbipd-win is not installed or the terminal was opened before the installation. See [3.1](#31-install-usbipd-win-on-windows). |
| `WARNING: 'usbipd' service not found`. | usbipd-win is not installed, or an old version (3.x) is installed. Install 4.0 or newer. |
| A UAC prompt appears even though the devices were bound before. | A device was plugged into a different USB port and received a new bus ID, or Windows Update replaced its driver. Accept the prompt; binding is quick. |
| `usbipd list` shows `Shared` but never `Attached`. | WSL was not running when you pressed Enter at Step 2. Open a WSL terminal and run `run.bat` again. |
| `lsusb` in WSL does not show the device. | Look at `dmesg \| tail -20` inside WSL for driver messages. Also check that the `usbipd` auto-attach process is running (Task Manager, or `Get-Process usbipd` in PowerShell). |
| The device needs `sudo` in WSL. | The udev rule was not applied. Run `sudo udevadm control --reload-rules && sudo udevadm trigger`, then unplug and re-plug the device. If the device is not in `devices.psd1`, add it there and run `run.bat` again. |
| `setup_interface_for_wsl.sh` fails with `syntax error` or `$'\r': command not found`. | The file has CRLF line endings. Save it with LF (VS Code: click `CRLF` in the status bar) or run `sed -i 's/\r$//' setup_interface_for_wsl.sh` inside WSL. |
| `No enx* interface found`. | The ASIX adapter is not plugged in, not attached, or the kernel lacks the driver. Check `lsusb` for `0b95:1790` and `dmesg \| grep ax88179`. |
| `WARNING: Requested MTU 4000 but interface reports 1500`. | No jumbo-frame driver for this kernel. Run `./build_ko.sh` inside WSL ([9.4](#94-building-the-driver-for-a-new-kernel)), then `run.bat` again. `ko/ko_lib.sh status` shows what is stored. |
| `build_ko.sh` says `no source found for kernel ...`. | WSL has no internet access, or Microsoft has not tagged this kernel version yet. Check the tags at <https://github.com/microsoft/WSL2-Linux-Kernel/tags>; if one exists under a different name, pass it with `--ref`. |
| `build_ko.sh` says `CRC mismatch`. | The source tag or config does not match the running kernel. Make sure you did not pass `--ref` or `--config` by accident. Do not use `--force` unless you know what you are doing; a mismatched module is refused by the kernel anyway. |
| `build_ko.sh` says `do not run as root`. | Run it from a normal user shell, not `sudo ./build_ko.sh`. It asks for `sudo` by itself where needed. |
| The IP address or MTU is gone after a WSL restart. | Expected. The settings are not persistent; run `run.bat` or the shell script again (see [7](#7-everyday-use)). |
| Device shows up on Windows but not in WSL after `restore.bat` and a later `run.bat`. | Give Windows a few seconds after unbinding before running `run.bat`, so the driver switch has finished. |

---

## 12. Good to know

- **Binding with `--force`** installs a stub driver on Windows. The device is
  unusable on Windows until you unbind it (`restore.bat`), even after a reboot.
- **udev rules use `MODE="0666"`**, which means every user in your WSL
  distribution can open the devices listed in `devices.psd1`. Fine for a single-user developer PC;
  tighten the rules if that is not your situation.
- **Only one WSL distribution** can own an attached device at a time. `usbipd
  attach --wsl` targets the default distribution.
- **Build records.** Each `ko/<release>/BUILD_INFO.txt` names the kernel source
  tag and commit, the config source, the compiler version and the result of the
  CRC verification, so you can tell exactly what a stored module is.
- **Nothing is installed on Windows** apart from usbipd-win. Deleting the
  repository folder after running `restore.bat` leaves no trace on Windows. In
  WSL, the udev rule file, the installed driver and its backup under
  `/var/lib/usbipd-setup-wsl/` remain and can be removed by hand.

---

## License

MIT License. See [LICENSE](LICENSE).

The patched `ax88179_178a.ko` files under `ko/` are built from the Linux kernel
source and are therefore covered by the kernel's own license (GPL-2.0), not by
the MIT license of the scripts.
