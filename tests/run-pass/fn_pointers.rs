// expect-exit: 30
// rustc-flags: -C panic=abort -C default-linker-libraries

#![no_std]
#![no_main]

use core::panic::PanicInfo;

#[panic_handler]
fn panic(_info: &PanicInfo) -> ! {
    loop {}
}

fn double(n: i32) -> i32 {
    n * 2
}

fn square(n: i32) -> i32 {
    n * n
}

fn apply(f: fn(i32) -> i32, n: i32) -> i32 {
    f(n)
}

fn pick(square_it: bool) -> fn(i32) -> i32 {
    if square_it { square } else { double }
}

fn twice(f: fn(i32) -> i32, n: i32) -> i32 {
    f(f(n))
}

extern "C" fn negate(n: i32) -> i32 {
    -n
}

fn nothing() {}

#[unsafe(no_mangle)]
pub extern "C" fn main() -> i32 {
    let f: fn(i32) -> i32 = double;
    if f(4) != 8 {
        return 1;
    }
    if apply(square, 5) != 25 || apply(pick(false), 5) != 10 {
        return 2;
    }
    if twice(pick(true), 3) != 81 {
        return 3;
    }
    let c: extern "C" fn(i32) -> i32 = negate;
    if c(7) != -7 {
        return 4;
    }
    let unit: fn() = nothing;
    unit();
    twice(double, 5) + apply(double, 5)
}
