// expect-panic: attempt to add with overflow
// rustc-flags: -C panic=abort -C default-linker-libraries -C overflow-checks=on

#![no_std]
#![no_main]

use core::panic::PanicInfo;

unsafe extern "C" {
    fn abort() -> !;
}

#[panic_handler]
fn panic(_info: &PanicInfo) -> ! {
    unsafe { abort() }
}

// libcore is compiled to unwind, and on Linux its unwind tables name this function even where panics abort. `std`
// defines it; a `no_std` program that reaches libcore's panic functions has to.
#[unsafe(no_mangle)]
pub extern "C" fn rust_eh_personality() {}

#[inline(never)]
fn add_one(n: u8) -> u8 {
    n + 1
}

#[unsafe(no_mangle)]
pub extern "C" fn main() -> i32 {
    let mut n = 250u8;
    let mut steps = 0;
    while steps < 10 {
        n = add_one(n);
        steps += 1;
    }
    n as i32
}
