// expect-stdout: written through a pointer and a length
// expect-stdout: alpha
// expect-stdout: beta
// expect-stdout: gamma
// expect-stdout: a C string
// expect-stdout: the last line, through a static of the C library
// rustc-flags: --edition 2024 -C panic=abort -C default-linker-libraries

#![no_std]
#![no_main]

use core::panic::PanicInfo;

unsafe extern "C" {
    fn abort() -> !;
}

// A check that panics is a failed test, not one that hangs.
#[panic_handler]
fn panic(_info: &PanicInfo) -> ! {
    unsafe { abort() }
}

// libcore is compiled to unwind, and on Linux its unwind tables name this function even where panics abort. `std`
// defines it; a `no_std` program that reaches libcore's panic functions has to.
#[unsafe(no_mangle)]
pub extern "C" fn rust_eh_personality() {}

use core::ffi::{CStr, c_char, c_int, c_void};

unsafe extern "C" {
    fn write(descriptor: c_int, bytes: *const u8, count: usize) -> isize;
    fn puts(text: *const c_char) -> c_int;
    fn fputs(text: *const c_char, stream: *mut c_void) -> c_int;
    fn fflush(stream: *mut c_void) -> c_int;

    // A static this program only declares: the C library defines it, under another name on macOS.
    #[cfg_attr(target_os = "macos", link_name = "__stdoutp")]
    static stdout: *mut c_void;
}

static LINES: [&str; 3] = ["alpha\n", "beta\n", "gamma\n"];
static FAREWELL: &CStr = c"the last line, through a static of the C library\n";

#[inline(never)]
fn print(text: &str) -> bool {
    unsafe { write(1, text.as_ptr(), text.len()) == text.len() as isize }
}

#[inline(never)]
fn print_c(text: &CStr) -> bool {
    unsafe { puts(text.as_ptr()) >= 0 && fflush(stdout) == 0 }
}

#[unsafe(no_mangle)]
pub extern "C" fn main(_one: i32, _arguments: *const *const u8) -> i32 {
    if !print("written through a pointer and a length\n") {
        return 1;
    }
    let mut index = 0;
    while index < LINES.len() {
        if !print(LINES[index]) {
            return 2;
        }
        index += 1;
    }
    if !print_c(c"a C string") {
        return 3;
    }
    unsafe {
        if fputs(FAREWELL.as_ptr(), stdout) < 0 || fflush(stdout) != 0 {
            return 4;
        }
    }
    0
}
