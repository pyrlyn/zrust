// expect-exit: 7
// rustc-flags: -C panic=abort -C default-linker-libraries

#![no_std]
#![no_main]

use core::panic::PanicInfo;

#[panic_handler]
fn panic(_info: &PanicInfo) -> ! {
    loop {}
}

// Nothing calls these two yet: they are here for their signatures.
#[unsafe(no_mangle)]
pub extern "C" fn first_of(first: i64, _second: u8) -> i64 {
    first
}

#[unsafe(no_mangle)]
pub extern "C" fn same_flag(flag: bool) -> bool {
    flag
}

#[unsafe(no_mangle)]
pub extern "C" fn main() -> i32 {
    let _byte: u8 = 200;
    let _wide: i64 = -3;
    let _flag = true;
    let _real = 1.5f64;
    let _unit = ();
    let code: i32 = 7;
    let copy = code;
    let moved = copy;
    moved
}
