// expect-exit: 0
// rustc-flags: -C panic=abort -C default-linker-libraries

#![no_std]
#![no_main]

use core::panic::PanicInfo;

#[panic_handler]
fn panic(_info: &PanicInfo) -> ! {
    loop {}
}

// Every value below is derived from `one`, the argument count of the process, so that neither rustc nor LLVM can
// compute the checks while compiling.

fn signed(one: i32) -> bool {
    let seven = one * 7;
    let minus_seven = -seven;
    seven + 5 == 12
        && seven - 10 == -3
        && seven * seven == 49
        && seven / 2 == 3
        && minus_seven / 2 == -3
        && seven % 3 == 1
        && minus_seven % 3 == -1
        && (seven & 5) == 5
        && (seven | 8) == 15
        && (seven ^ 2) == 5
        && !seven == -8
        && seven << 2 == 28
        && minus_seven >> 1 == -4
        && minus_seven < seven
        && minus_seven <= -7
        && seven > 6
        && seven >= 7
        && seven != 8
}

fn unsigned(one: i32) -> bool {
    let top = (one as u32) << 31;
    let byte = one as u8 * 200;
    top > 7
        && top >> 31 == 1
        && top / 2 == 1 << 30
        && top % 1000 == 648
        && top - 1 == 0x7fff_ffff
        && byte / 3 == 66
        && byte >> 1u64 == 100
        && byte.wrapping_add(byte) == 144
        && byte.wrapping_mul(3) == 88
        && (byte as u16) << 4i8 == 3200
        && !byte == 55
}

fn wide(one: i32) -> bool {
    let big = (one as u64) << 40;
    let huge = (one as u128) << 100;
    let minus = -(one as i128) << 90;
    big + big == 1 << 41
        && big * 3 - 1 == 3298534883327
        && huge + huge == 1 << 101
        && huge >> 64 == 1 << 36
        && huge * 5 > huge
        && (huge | 1) & 0xff == 1
        && minus < 0
        && minus >> 90 == -1
        && minus as u128 > huge
}

fn floats(one: i32) -> bool {
    let x = one as f64 * 1.5;
    let small = one as f32 / 4.0;
    let infinity = x / 0.0;
    let nan = infinity - infinity;
    x + 2.25 == 3.75
        && x - 2.0 == -0.5
        && x * x == 2.25
        && x / 2.0 == 0.75
        && -x < 0.0
        && x > 1.0
        && x >= 1.5
        && x <= 1.5
        && x != 2.0
        && !(x < 1.5)
        && small + small == 0.5
        && small * -8.0 == -2.0
        && infinity > 1e300
        && nan != nan
        && !(nan == nan)
        && !(nan < x)
        && !(nan >= x)
}

fn logic(one: i32) -> bool {
    let yes = one == 1;
    let no = !yes;
    let letter = if yes { 'x' } else { 'y' };
    (yes & !no)
        && (yes | no)
        && (yes ^ no)
        && !(no ^ no)
        && yes != no
        && no < yes
        && letter == 'x'
        && letter > 'a'
        && letter <= '\u{10ffff}'
}

#[unsafe(no_mangle)]
pub extern "C" fn main(one: i32, _arguments: *const *const u8) -> i32 {
    if !signed(one) {
        return 1;
    }
    if !unsigned(one) {
        return 2;
    }
    if !wide(one) {
        return 3;
    }
    if !floats(one) {
        return 4;
    }
    if !logic(one) {
        return 5;
    }
    0
}
