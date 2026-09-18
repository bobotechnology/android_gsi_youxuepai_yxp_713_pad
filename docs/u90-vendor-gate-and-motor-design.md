# U90 vendor boot gate and popup front camera motor control

## Scope

Two independent device defects are addressed:

1. The touchscreen (and several vendor sensors) never report input on the
   Android 11 GSI.
2. The pop-up front camera is never raised, because the vendorspace component
   that drives its motor is absent from the GSI.

Both are fixed on the `system` partition only. `boot`, `dtbo`, `recovery`,
`kernel`, and `userdata` stay untouched.

## Defect 1: vendor boot-animation gate

### Root cause

The stock U90 kernel gates several vendor drivers on a global flag at kernel
`.bss` offset `0x1d4bc30`. When that flag is zero, `himax_ts_work()`
(file offset `0xaba97c`) takes an early return at `0xaba994`
(`cbz w8, 0xabaaf4`) and emits no input events at all.

The flag is set only by the bootprof handler that compares a user-supplied line
against the literal `BOOT_Animation:END`:

```asm
0x00506394  ldrb w8, [x23, 0xc44]     ; bootprof logging still enabled?
0x0050639c  cmp  w8, 1
0x005063a0  b.ne 0x50654c             ; disabled -> skip everything below
0x005063d8  add  x0, x0, 0x202         ; "BOOT_Animation:END"
0x005063e0  mov  w2, 0x11              ; 17 bytes
0x005063e8  bl   0x35ecb0              ; strncmp(input, marker, 17)
0x005063ec  cbnz w0, 0x506408
0x00506400  str  w9, [x8, 0xc30]       ; flag = 1
```

In stock Android 10 the MediaTek-modified `SurfaceFlinger` writes that marker
when the boot animation finishes. `/system/lib64/libsurfaceflinger.so` contains
`BOOT_Animation:START` and `BOOT_Animation:END`; the AOSP `SurfaceFlinger`
shipped with this GSI contains neither, so the marker is never written and the
vendor drivers stay muted forever.

The same flag also gates the hall sensor and other vendor sensor drivers
(confirmed by nine independent readers of `0x1d4bc30` in the kernel image,
spanning the Himax touchscreen, the hall driver, and further vendor sensors).

`/proc/bootprof` is world-writable by `system`, and the vendor
`/vendor/etc/init/hw/init.mt6779.rc` disables bootprof logging on
`property:sys.boot_completed=1`. Writing the marker after that point is
silently discarded, which is why a late runtime write does not help.

### Design

The write must come from a domain that the vendor SELinux policy actually
permits. `vendor_sepolicy.cil` grants `write` on `proc_bootprof` only to:

```text
vendor_init_29_0      surfaceflinger_29_0
system_server_29_0    vold_29_0
```

There is no rule for the AOSP `init` domain. An init action shipped in
`/system/etc/init/` runs as `init`, so its write is denied even though the file
mode is `0666`. This was tested on the device: an init-based rc installed the
file correctly, the action ran at `post-fs-data`, and the marker still never
reached the kernel (the kernel's match-only printk never appeared, and
`/proc/bootprof` recorded seven `INIT:` lines from `vendor_init` but zero
`BOOT_Animation` entries).

The working hook is the one the stock MediaTek `SurfaceFlinger` used: write the
marker from `SurfaceFlinger::bootFinished()`, which is exactly where the boot
animation is asked to exit:

```cpp
    // stop boot animation
    property_set("service.bootanim.exit", "1");
```

`SurfaceFlinger::init()` is patched as well, so the marker is also written as
early as possible. Writing it twice is harmless: the kernel only string-compares
the line and sets a flag.

The usable window opens early and closes when `vendor_init` writes the bootprof
off switch on `sys.boot_completed=1`. Measured on the device, `INIT:early-init`
is recorded at 7.6 s and the `OFF` marker at 30.8 s, so both hook points sit
inside the window.

Delivered as `gsi/patches/frameworks-native/0001-u90-vendor-input-gate.patch`,
which is the first patch in the recipe to touch `frameworks/native`. Validated:
applies cleanly at revision `5152e839903c9106a3e029e153ee7c81034d367b`, adds the
`fcntl.h`/`unistd.h` includes, and produces both write sites.

Kernel and boot image are not touched.

## Defect 2: pop-up front camera motor

### Root cause

The front camera is mounted on a lift mechanism with two Hall-detected
positions. The kernel exposes a char device and a platform driver:

```text
/dev/NOAH_MOTOR        char major 215, stock mode 0666 root:root
/sys/devices/platform/noah_motor/{motor_position,motor_status,motor_force_stop,
                                   motor_irq_enable,motor_cali_info,
                                   hall_name,hall_value_show}
compatible: noah,noah_motor      chip driver: noah_motor_drv8646
hall: ist8801 (eint 8 ist8801_down, eint 14 ist8801_up)
ro.noah.hw.cam_lift_motor=1
```

Current state is `motor_position = position_bottom`, i.e. retracted.

The userspace stack that drives it is absent from the GSI:

```text
/system/app/MotorMonitor/     service side, AIDL IMotorMonitor
/system/app/CameraMotor/      client UI
com.noahedu.fw.noahsys.util.NoahMotorCtrl   inside /system/framework/framework.jar
```

`MotorMonitor` decides when to raise based on Noah launcher broadcasts
(`noah.action.sys.TOP_PACKAGE_CHANGE`, `noah.action.motor.STATUS_NOTIFY`) and a
hardcoded camera-package whitelist. Porting that whole stack would mean pulling
vendor APKs plus Noah framework classes that do not exist in AOSP 11.

The underlying movement is a single ioctl, and the closed loop lives in the
kernel (the Hall GPIO interrupts drive the motor stop). So the design replaces
the vendor policy layer instead of porting it.

### Motor protocol (reverse engineered)

From `/system/lib64/libfactorytestjni.so` (44176 bytes), the Java entry points
are thin wrappers over `ioctl()` on the fd stored by `openMotorDevice`:

```text
open("/dev/NOAH_MOTOR", O_RDWR)      -> fd saved in module .bss
ioctl(fd, request, &arg)
close(fd)
```

All requests share one `_IOC` encoding — `dir=1` (`_IOC_WRITE`), `size=0x00c4`,
`type=0x4d` (`'M'`) — and differ only in `nr`. The driver does not decode the
`_IOC` fields individually: `noah_motor_drv_ioctl` (file offset `0x9a7808`)
subtracts the whole command word from `0x40c44d00` and requires the result to be
within `[0, 0x10]`:

```text
0x9a7848  mov  w8, 0xb300
0x9a784c  movk w8, 0xbf3b, lsl 16      ; w8 = -0x40c44d00
0x9a7850  add  w8, w1, w8              ; w8 = cmd - 0x40c44d00
0x9a7854  cmp  w8, 0x10
0x9a7858  mov  x0, xzr                 ; return value preset to 0
0x9a785c  b.hi 0x9a7914                ; out of range -> epilogue, returns 0
0x9a7860  adrp x9, 0x1007000
0x9a7864  add  x9, x9, 0xfe0           ; byte jump table at 0x1007fe0
0x9a786c  ldrb w11, [x9, x8]           ; index by nr
0x9a7878  br   x10
```

Two consequences matter in practice. First, if `dir`, `type`, or `size` is wrong
the command is out of range and the epilogue returns **0**, not `-EINVAL` — a
miscoded command is indistinguishable from success. Second, `0x9a7914` is the
epilogue itself, so any jump-table entry pointing there is an empty stub: no
action, no log, no error.

The table is the authoritative list of what the kernel implements:

| nr | request      | target     | implemented behaviour                     |
| -- | ------------ | ---------- | ----------------------------------------- |
| 0  | `0x40c44d00` | `0x9a787c` | stop motor                                |
| 1  | `0x40c44d01` | `0x9a7938` | **move; the int argument is the mode**     |
| 2  | `0x40c44d02` | `0x9a7914` | empty stub                                |
| 3  | `0x40c44d03` | `0x9a7914` | empty stub (PWM params come from the DTS) |
| 4  | `0x40c44d04` | `0x9a79ac` | `copy_from_user(4)`                       |
| 5  | `0x40c44d05` | `0x9a79ec` | read Hall data                            |
| 6  | `0x40c44d06` | `0x9a7a48` | start calibration (wakes a thread)        |
| 7  | `0x40c44d07` | `0x9a7a7c` | set/clear `is_test`                       |
| 8  | `0x40c44d08` | `0x9a7914` | empty stub                                |
| 9  | `0x40c44d09` | `0x9a7acc` | start Hall recording (wakes a thread)     |
| 10 | `0x40c44d0a` | `0x9a7ae8` | read Hall calibration data                |
| 11 | `0x40c44d0b` | `0x9a7914` | empty stub                                |
| 12 | `0x40c44d0c` | `0x9a7914` | empty stub                                |
| 13 | `0x40c44d0d` | `0x9a7b38` | read Hall record data                     |
| 14 | `0x40c44d0e` | `0x9a7914` | empty stub                                |
| 15 | `0x40c44d0f` | `0x9a7b88` | read current position                     |
| 16 | `0x40c44d10` | `0x9a7bd8` | set/clear `irq_enable`                    |

**The stock factory-test library is a trap here.** Its
`Java_..._MotorCtrl_startMotor(int mode)` indexes a table at `0x5b20` and calls
`ioctl(fd, table[mode], &v)` with `v` hardcoded to `1`:

```text
table = {0x40c44d00, 0x40c44d01, 0x40c44d02, 0x40c44d08}
mode 0 -> nr 0    mode 1 -> nr 1    mode 2 -> nr 2    mode 3 -> nr 8
```

so `mode 2` and `mode 3` land on stubs and the library can only ever move to
`position_top` (via `mode 1`, whose argument happens to be `1`). The vendor's
real control path did not go through that table: it passed the target as the
argument to `nr 1`. This tool follows the vendor path.

### Mode semantics

`NoahMotorCtrl$EnumMotorMode.<clinit>` (in `framework.jar` `classes3.dex`)
constructs four enum constants with `(ordinal, name, mode)`:

```text
EM_STOP_MODE   ordinal 0  name STOP_MODE    mode 0
EM_AR_MODE     ordinal 1  name AR_MODE      mode 1
EM_DOWN_MODE   ordinal 2  name DOWN_MODE    mode 2
EM_SELFIE_MODE ordinal 3  name SELFIE_MODE  mode 3
```

These mode numbers are the argument to `nr 1`. Kernel side,
`noah_motor_control` (file offset `0x9a7494`) does `cmp w19, 4` and indexes a
position table `[0, 0, 1, 2, 3]` at `0x10081c8`, where the position names are
`position_top`, `position_bottom`, `position_selfie`, `position_phy_middle`.
Kernel-internal callers use **mode 2** exclusively for reset, error recovery,
and shutdown paths.

Resulting mapping, confirmed on the device:

| mode | name          | target position   | physical meaning                                  |
| ---- | ------------- | ----------------- | ------------------------------------------------- |
| 0    | `STOP_MODE`   | -                 | stop motor, no position move                      |
| 1    | `AR_MODE`     | `position_top`    | fully raised, lens looks down (desk/AR capture)   |
| 2    | `DOWN_MODE`   | `position_bottom` | retracted                                         |
| 3    | `SELFIE_MODE` | `position_selfie` | raised, lens faces the user (normal front camera) |

The two raised positions are distinct heights, confirmed by the kernel's
calibration values: `hall_value_top = 311`, `hall_value_selfie = 43`.

For the ordinary front camera the framework selects `SELFIE_MODE`, so mode 3 is
the mode this work uses.

### Movement guards inside the driver

`nr 1` reaches `noah_motor_control` only after two checks
(`0x9a7de0`-`0x9a7dfc`):

```text
if (is_calibrated == 0)            ; [p+0x400]
    require is_test != 0           ; [p+0x39d], else silent return
require hall_usable != 0           ; [p+0x405], else "hall can not use" + return
```

`is_test` is settable from userspace with `nr 7` and overrides the check, so on
a unit that reports unusable Hall feedback `u90-motor raw 7 1` is the documented
escape hatch. That path is deliberately not wired into any automatic flow: with
the Hall loop unavailable the motor has no way to stop itself at the target.

On the working unit neither guard blocks: `is_calibrated = 1`,
`hall_usable = 1`, and `nr 1` moves the lift in both directions with the kernel
logging the full Hall closed loop:

```text
[Noah_Motor]speed up start!
[Noah_8646]period 78125, L_duration 506, H_duration 506, wave 0
[Noah_8646]period 26041, L_duration 168, H_duration 168, wave 0
[Noah_Motor]timer  stop motor!!
[Noah_Motor]hall0_val =42,cali_data.hall_value_selfie =43
[Noah_Motor]motor arrive to selfie position successful!
[Noah_Motor]noah_update_motor_position end :: motor_position = position_selfie
```

### Design

Reimplement the minimal policy layer instead of porting the vendor stack.

**Component:** **`tools/u90-motor`** **(C++ command line)**

A single-purpose tool that owns the device protocol:

```text
u90-motor status            read motor_position / motor_status / hall (no movement)
u90-motor up                SELFIE_MODE  -> front camera usable
u90-motor ar                AR_MODE      -> desk/AR position
u90-motor down              DOWN_MODE    -> retract
u90-motor stop              STOP_MODE
u90-motor raw <nr> [value]  send an arbitrary request (diagnostics only)
```

Every movement command follows the same safe sequence: open, send, then poll
`sysfs motor_position` until it reports the requested target or a timeout
expires. On timeout the tool stops and reports; it never retries blindly, so a
blocked mechanism cannot be driven against a stall.

Source lives in `gsi/tools/u90-motor/` and is built as a platform `cc_binary`
into `/system/bin/u90-motor`. `stage_u90_motor()` in `apply-u90-patches.sh`
copies it into `device/phh/treble/u90-motor/` and makes the product inherit
`u90-motor.mk`, the same mechanism the recipe already uses for Fcitx5.

The ioctl argument is a pointer to a scratch `int`, not a value: the driver does
`copy_from_user` from it and reads the mode out of the copied int. The stock
wrapper at `0x8b44`-`0x8b90` stores `1` to `[sp, #4]`, passes `sp + 4` as the
third argument, and returns whatever the driver leaves there:

```text
0x8b48  str w9, [sp, #4]           ; w9 = 1
0x8b58  ldr w19, [x8, w3, sxtw 2]  ; request = table[mode]
0x8b84  add x2, sp, #4             ; ioctl argument = &int
0x8b8c  bl ioctl
0x8b90  ldr w0, [sp, #4]           ; return value
```

`u90-motor` passes `nr 1` with the target mode in that int, and sizes the scratch
area for the largest request in the family (`0xc04`, the Hall record read) so a
`raw` call cannot under-size the buffer.

**Component: device node access**

The GSI creates `/dev/NOAH_MOTOR` as `0600 root:root u:object_r:device:s0`.
Stock grants `0666 root root` from its ueventd rules. Ship the same rule so
non-root system components can open the node, plus a dedicated SELinux type so
the access is labelled rather than falling back to `device`.

The dedicated type is not cosmetic. `system/sepolicy/public/domain.te` carries
`neverallow domain device:chr_file { open read write }`, so `cameraserver` could
never be granted the node while it stays labelled `device`.

Delivery is split because the two halves rebuild differently:

- the ueventd rule is a patch to `system/core/rootdir/ueventd.rc`, which is a
  tracked file that survives `git clean -fdx`;
- `sepolicy/noah_motor.te` and the `file_contexts` entry are staged by
  `stage_u90_sepolicy()` in `apply-u90-patches.sh`. A patch cannot own the new
  `.te` file: `prepare_android_source` runs `git clean -fdx` on
  `device/phh/treble` before patching, which deletes untracked files but keeps
  tracked modifications, leaving the tree in a state where the patch neither
  applies forward nor reverses. Staging both halves is idempotent.

**Component: automatic trigger**

Hook the existing `frameworks/av` patch path — the recipe already patches that
tree for the front camera orientation override. `CameraService` observes every
camera connect/disconnect regardless of which app is in front, which replaces
the vendor's whitelist-and-broadcast policy:

- front camera `connect()` -> `up` (SELFIE)
- front camera `disconnect()` -> `down`

The hook is placed at the two call sites that already track the physical front
camera, both scoped to the front camera id:

- `CameraService::connectHelper()` next to the existing
  `physicalFrontCam(cameraId == "1")`
- `CameraService::BasicClient::disconnect()` next to the existing
  `physicalFrontCam(false)`

Upstream `physicalFrontCam()` is deliberately left untouched. It takes a bare
`bool`, so its `false` cannot be told apart between "the front camera was
released" and "some other camera was opened or closed"; routing the U90 branch
through it would retract the lift whenever any other camera is touched while the
front camera is still streaming. Scoping at the call sites also removes the need
for the dedup that `mPhysicalFrontCamStatus` provides: every event that reaches
the hook is a real front-camera state change.

The lift is driven by `ioctl` directly rather than by forking a helper, which
keeps the SELinux surface to one `chr_file` rule and avoids an exec transition.
It sends `nr 1` with mode 3 to raise and mode 2 to retract. The earlier revision
of this patch used `nr 8` and `nr 2` (mirroring the stock factory-test table) and
therefore did nothing at all: both are empty stubs.

Known limitation of hooking at `connect()`. The sensor is opened at the same
moment the lift starts moving, and the lift needs about 1.3 s to travel
(`1681.98` to `1683.26` in the kernel log above), so the first frames of a front
camera session are captured before the module has reached the selfie position.
The vendor avoided this by raising the lift on an app-launch broadcast, before
the sensor was opened. Raising it earlier here would require the same kind of
launch heuristic, which is out of scope. The hook deliberately does not wait for
the move to finish, because it runs while `mServiceLock` is held and blocking
there for over a second would stall every other camera connection.

### Which camera id is the lift

`dumpsys media.camera` on the device reports five HAL devices:

| id | facing | orientation | conflicting devices |
| -- | ------ | ----------- | ------------------- |
| 0  | Back   | 90          | none                |
| 1  | Front  | 270         | 4                   |
| 2  | Front  | 270         | none                |
| 3  | Front  | 270         | 4                   |
| 4  | Front  | —           | 1, 3                |

Device 4 advertises `android.logicalMultiCamera.physicalIds` and is the only one
that does, so it is the logical multi-camera synthesised from 1 and 3. The
primary physical front camera is therefore **id 1**, which is also the id the
upstream PHH hook and the front-camera orientation override already target.

That id is hardcoded as `"1"` in both `frameworks/av` patches
(`getU90FrontCameraOrientation()` and `kU90FrontCameraId`), and upstream's own
`physicalFrontCam(cameraId == "1")` does the same. It is deliberately left as a
device constant rather than moved to a property: the value follows from the
provider layout of exactly one SKU, and unlike the sensor orientation — which had
four plausible values and was settled experimentally, so it is read from
`ro.u90.camera.front.orientation` — there is no other candidate to choose between
at build time. A property would only add a way to set it wrong, with the failure
mode being a silently missing lift rather than a visible error.

## Verification ladder

Each stage is a single variable change, and every movement stage reads position
back before and after.

| stage | action                              | pass condition                                                 | result |
| ----- | ----------------------------------- | -------------------------------------------------------------- | ------ |
| 1     | build and flash the touch gate only | `getevent` on `event10`/`event11` reports touches; UI responds  | pass   |
| 2     | `u90-motor status`                  | prints `position_bottom`; no movement                           | pass   |
| 3     | `u90-motor up` / `u90-motor down`   | `motor_position` follows the command in both directions         | pass   |
| 4     | open the camera, switch to front    | front camera streams                                            | pass   |
| 5     | retract the lift                    | `motor_position` returns to `position_bottom`                   | pass   |
| 6     | enable the `CameraService` hook     | front camera raises and retracts automatically                  | pass   |

Stage 1 is deliberately first: it validates the whole build/package/flash chain
with an already-proven patch before any mechanical risk is introduced.

Notes on the recorded results:

- Stage 3 is driven by the tool's own commands, which send `nr 1` with mode 3
  (`up`) and mode 2 (`down`). The device log shows the move in both directions,
  with the kernel's Hall closed loop deciding the stop:

  ```text
  [Noah_Motor]hall0_val =42,cali_data.hall_value_selfie =43
  [Noah_Motor]motor arrive to selfie position successful!
  [Noah_Motor]noah_update_motor_position end :: motor_position = position_selfie

  [Noah_Motor]hall1_val =363,cali_data.hall_value_bottom =348
  [Noah_Motor]motor arrive to bottom position successful!
  [Noah_Motor]noah_update_motor_position end :: motor_position = position_bottom
  ```

- Stage 4 passed on streaming evidence plus a captured frame, not on a rendered
  screenshot. `screencap` returned black (the preview is a hardware overlay it
  does not capture), so the check that settles it is a still capture:
  `dumpsys media.camera` showed `Device 1 is open` for `com.android.camera2`, and
  `input keyevent 27` produced a 3456x4608 JPEG with
  `ISO 1925` / `ExposureTime 0.100004 s`. A 16 MP frame at ISO 1925 with a 0.1 s
  exposure, whose luma histogram decays geometrically from 0 up to 39, is a real
  sensor integration of a nearly unlit scene, not a dead stream.

- Stage 6 is confirmed end to end. Opening the camera and closing it moves the
  lift both ways with no other action:

  ```text
  position_before_open  = position_bottom
  position_after_open   = position_selfie
  position_after_close  = position_bottom

  02:35:13.992  I CameraService: U90 front camera lift up
  02:35:20.595  I CameraService: U90 front camera lift down
  ```

  Two things made this harder to observe than it should have been, and both are
  test-harness artefacts rather than firmware behaviour:

  - `am start` alone does not make the app eligible to open the camera. With the
    notification shade covering the screen the app never became the focused
    window and `validateConnectLocked()` rejected the connection with
    `Access Denial: can't use the camera from an idle UID` -- that check runs
    *before* the hook, so the hook silently never ran. Waking the screen and
    dismissing the keyguard is what makes the test valid.
  - The default logcat buffer is 256 KiB per buffer and a camera preview session
    wraps it within seconds, which evicted the `lift up` line and made it look as
    though only the retract had happened. `logcat -G 16M` before the run keeps
    both events.

## Risks

- The lift mechanism is physical. A wrong or repeated command can stall or
  damage it. Mitigations: read position first, single step per action, bounded
  polling, no automatic retry, and a read-only `status` command used before
  every movement.
- Lowering the device node to `0666` widens access to the motor from any
  process that can reach the SELinux type. The dedicated type keeps that
  scoped, and the alternative (root-only node) cannot work for a normal system
  service.
- `is_test` (set with `raw 7 1`) bypasses the driver's Hall-availability check.
  It must not be wired into any automatic path: without the Hall loop the motor
  has no way to stop itself at the target. It exists in the tool as a manual
  diagnostic only.
- A miscoded request returns success. The driver answers 0 for anything outside
  its jump table, so a wrong command word, and any of the empty stubs, look
  exactly like a successful move. Both the tool and `validate-recipe.sh` carry an
  explicit guard against reintroducing the stub numbers.

## Out of scope

- Porting `MotorMonitor`, `CameraMotor`, or any other Noah application or UI.
- The Noah framework classes in `framework.jar`.
- AR/desk mode automation. It stays available through `u90-motor ar` but is not
  wired to any camera flow.
- Anything on `boot`, `dtbo`, `recovery`, `kernel`, or `userdata`.

