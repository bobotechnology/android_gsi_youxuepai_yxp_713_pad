/*
 * U90 (yxp_713_pad) front-camera lift motor control.
 *
 * One movement request reaches the driver, and the target is its int argument:
 *
 *     fd = open("/dev/NOAH_MOTOR", O_RDWR);
 *     int mode = <target>;
 *     ioctl(fd, 0x40c44d01, &mode);
 *
 * The driver always reads the argument as a pointer, so a pointer to a scratch
 * area is required. The movement requests only read the first int, but other
 * requests in the same family write larger structures, so every request gets a
 * buffer sized for the largest of them (see kMaxRequestBytes below).
 *
 *   mode 0  stop    motor stops where it is
 *   mode 1  AR      position_top     (raised fully, lens faces down)
 *   mode 2  down    position_bottom  (retracted)
 *   mode 3  selfie  position_selfie  (raised partly, lens faces the user)
 *   mode 4  phy_middle
 *
 * Do not follow the stock /system/lib64/libfactorytestjni.so here. Its
 * startMotor(mode) does `ioctl(fd, table[mode], &v)` with v hardcoded to 1 and
 * table = {nr 0, nr 1, nr 2, nr 8}, which sends mode 2 and mode 3 to nr 2 and
 * nr 8 -- both of which are empty stubs in this kernel that return success
 * without moving anything. Only table[0] and table[1] do real work, and
 * table[1] always moves to mode 1. The vendor's real control path passed the
 * target as the argument to nr 1 instead, which is what this tool does.
 *
 * The Hall closed loop lives in the kernel, so a movement request returns as
 * soon as the motor starts. This tool polls sysfs for the resulting position
 * and never retries, so a blocked mechanism cannot be driven against a stall.
 */

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>

namespace {

constexpr char kDevice[] = "/dev/NOAH_MOTOR";
constexpr char kSysfsRoot[] = "/sys/devices/platform/noah_motor";

// The driver does not use the _IOC size field at all: it subtracts 0x40c44d00
// from the whole command word and indexes a 17-entry jump table with the low
// byte. Anything whose dir, type, or size bits differ is out of range and the
// epilogue returns 0 without doing anything and without logging, so a wrong
// encoding looks exactly like success.
//
// The jump table is the authoritative list of what actually exists:
//
//   nr 0   stop                      implemented
//   nr 1   move, mode passed in arg  implemented
//   nr 2   (down)                    empty stub, returns 0
//   nr 3   (set PWM)                 empty stub, returns 0
//   nr 4   copy_from_user(4)         trivial
//   nr 5   read Hall                 implemented
//   nr 6   start calibration         wakes a kernel thread
//   nr 7   set/clear is_test         implemented
//   nr 8   (selfie)                  empty stub, returns 0
//   nr 9   start Hall recording      wakes a kernel thread
//   nr 10  read Hall calibration     implemented
//   nr 11/12/14                      empty stubs, return 0
//   nr 13  read Hall record          implemented
//   nr 15  read current position     implemented
//   nr 16  set/clear irq_enable      implemented
//
// So the stock factory-test table {00,01,02,08} has exactly one real movement
// command: nr 1. The mode is the int argument, and noah_motor_control indexes
// its position table with it: 1 -> position_top, 2 -> position_bottom,
// 3 -> position_selfie, 4 -> position_phy_middle.
constexpr unsigned long kRequestStop = 0x40c44d00UL;
constexpr unsigned long kRequestMove = 0x40c44d01UL;

constexpr unsigned long kRawRequestBase = 0x40c44d00UL;

constexpr int kModeTop = 1;
constexpr int kModeBottom = 2;
constexpr int kModeSelfie = 3;

constexpr int kPollIntervalMs = 25;
constexpr int kPollTimeoutMs = 4000;

// The driver copies only 4 bytes for the movement requests, but the Hall record
// read (nr 13) writes 0xc04 bytes, so the scratch area is sized for the largest
// request in the family.
constexpr size_t kMaxRequestBytes = 0xc04;

// sysfs attribute buffer. motor_cali_info is the longest attribute and is
// measured at 521 bytes on the device, so this leaves ample headroom.
constexpr size_t kAttributeBytes = 1024;

struct Command {
    const char* name;
    unsigned long request;
    // Value handed to the driver as the ioctl argument. For a movement it is
    // the target mode; for "stop" it is left at 1 to match the stock caller.
    int argument;
    // sysfs substring that must appear in motor_position once the move is done.
    // Null for "stop", which has no target position.
    const char* target;
};

constexpr Command kCommands[] = {
    {"stop", kRequestStop, 1, nullptr},
    {"ar", kRequestMove, kModeTop, "position_top"},
    {"down", kRequestMove, kModeBottom, "position_bottom"},
    {"up", kRequestMove, kModeSelfie, "position_selfie"},
};

void usage(FILE* out) {
    fprintf(out,
            "usage: u90-motor <command>\n"
            "\n"
            "  status            read position, Hall and motor state (no movement)\n"
            "  up                raise to the selfie position (ordinary front camera)\n"
            "  ar                raise fully to the AR position (lens faces down)\n"
            "  down              retract\n"
            "  stop              stop the motor where it is\n"
            "  raw <nr> [value]  send request 0x40c44d00+nr with an int argument\n"
            "\n"
            "The driver refuses to move the lift while its Hall feedback is\n"
            "unavailable; in that state a movement request succeeds but does\n"
            "nothing. Use raw 7 1 to set the driver's test flag to override that\n"
            "protection, understanding that the motor then has no way to stop\n"
            "itself at the target.\n");
}

long long monotonicMs() {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return static_cast<long long>(ts.tv_sec) * 1000 + ts.tv_nsec / 1000000;
}

// Reads a sysfs attribute into buffer, dropping the trailing newline.
bool readAttribute(const char* name, char* buffer, size_t size) {
    char path[256];
    snprintf(path, sizeof(path), "%s/%s", kSysfsRoot, name);

    const int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        snprintf(buffer, size, "<unreadable: %s>", strerror(errno));
        return false;
    }

    ssize_t count = read(fd, buffer, size - 1);
    close(fd);

    if (count < 0) {
        snprintf(buffer, size, "<unreadable: %s>", strerror(errno));
        return false;
    }

    buffer[count] = '\0';
    while (count > 0 && (buffer[count - 1] == '\n' || buffer[count - 1] == ' ')) {
        buffer[--count] = '\0';
    }
    return true;
}

void printAttribute(const char* name) {
    char value[kAttributeBytes];
    readAttribute(name, value, sizeof(value));
    printf("%-22s %s\n", name, value);
}

// Returns true when motor_position currently contains the given substring.
bool positionMatches(const char* substring) {
    char value[kAttributeBytes];
    if (!readAttribute("motor_position", value, sizeof(value))) {
        return false;
    }
    return strstr(value, substring) != nullptr;
}

void printPosition(const char* label) {
    char value[kAttributeBytes];
    readAttribute("motor_position", value, sizeof(value));
    printf("%s %s\n", label, value);
}

int commandStatus() {
    printAttribute("motor_position");
    printAttribute("motor_status");
    printAttribute("motor_force_stop");
    printAttribute("motor_irq_enable");
    printAttribute("hall_name");
    printAttribute("hall_value_show");
    printAttribute("hall_cali_value_show");
    printAttribute("motor_cali_info");
    return 0;
}

// Issues one request. Returns 0 when the ioctl succeeded, otherwise errno.
// The caller owns the scratch area and must size it to kMaxRequestBytes.
int issueRequest(unsigned long request, void* argument) {
    const int fd = open(kDevice, O_RDWR | O_CLOEXEC);
    if (fd < 0) {
        const int err = errno;
        fprintf(stderr, "u90-motor: cannot open %s: %s\n", kDevice, strerror(err));
        return err;
    }

    errno = 0;
    const int rc = ioctl(fd, request, argument);
    const int err = errno;
    close(fd);

    if (rc < 0) {
        fprintf(stderr, "u90-motor: ioctl(0x%08lx) failed: %s\n", request, strerror(err));
        return err ? err : EIO;
    }
    return 0;
}

// Polls motor_position until target appears or the deadline expires. Returns
// true when the target was observed.
bool waitForTarget(const char* target, long long deadlineMs) {
    while (monotonicMs() < deadlineMs) {
        if (positionMatches(target)) {
            return true;
        }
        usleep(kPollIntervalMs * 1000);
    }
    return positionMatches(target);
}

int commandMove(const Command& command) {
    printPosition("before:");

    // The driver reads the argument as the target mode, so the scratch area
    // holds the command's own argument rather than a fixed value.
    unsigned char scratch[kMaxRequestBytes];
    memset(scratch, 0, sizeof(scratch));
    reinterpret_cast<int*>(scratch)[0] = command.argument;

    const int err = issueRequest(command.request, scratch);
    if (err != 0) {
        return 1;
    }

    if (command.target == nullptr) {
        // "stop" has no target position; report where the motor actually is.
        printPosition("after: ");
        return 0;
    }

    const bool reached = waitForTarget(command.target, monotonicMs() + kPollTimeoutMs);
    printPosition("after: ");

    if (!reached) {
        fprintf(stderr, "u90-motor: %s did not reach %s within %d ms\n", command.name,
                command.target, kPollTimeoutMs);
        return 1;
    }
    return 0;
}

int commandRaw(int argc, char** argv) {
    if (argc < 3) {
        fprintf(stderr, "u90-motor: raw needs a request number\n");
        return 64;
    }

    char* end = nullptr;
    const long nr = strtol(argv[2], &end, 0);
    if (end == argv[2] || *end != '\0' || nr < 0 || nr > 0xff) {
        fprintf(stderr, "u90-motor: bad request number: %s\n", argv[2]);
        return 64;
    }

    int value = 1;
    if (argc >= 4) {
        end = nullptr;
        value = static_cast<int>(strtol(argv[3], &end, 0));
        if (end == argv[3] || *end != '\0') {
            fprintf(stderr, "u90-motor: bad argument value: %s\n", argv[3]);
            return 64;
        }
    }

    const unsigned long request = kRawRequestBase + static_cast<unsigned long>(nr);

    // Every request gets the full scratch area: the driver ignores _IOC_SIZE,
    // so a request that writes a larger structure (the Hall record read wants
    // 0xc04 bytes) must still land in a buffer big enough for it.
    unsigned char scratch[kMaxRequestBytes];
    memset(scratch, 0, sizeof(scratch));
    reinterpret_cast<int*>(scratch)[0] = value;

    const int err = issueRequest(request, scratch);
    if (err != 0) {
        return 1;
    }

    printf("request 0x%08lx returned %d\n", request, reinterpret_cast<int*>(scratch)[0]);
    return 0;
}

}  // namespace

int main(int argc, char** argv) {
    if (argc < 2) {
        usage(stderr);
        return 64;
    }

    if (strcmp(argv[1], "-h") == 0 || strcmp(argv[1], "--help") == 0) {
        usage(stdout);
        return 0;
    }

    if (strcmp(argv[1], "status") == 0) {
        return commandStatus();
    }

    if (strcmp(argv[1], "raw") == 0) {
        return commandRaw(argc, argv);
    }

    for (const Command& command : kCommands) {
        if (strcmp(argv[1], command.name) == 0) {
            return commandMove(command);
        }
    }

    fprintf(stderr, "u90-motor: unknown command: %s\n", argv[1]);
    usage(stderr);
    return 64;
}
