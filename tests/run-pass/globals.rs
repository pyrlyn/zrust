// expect-exit: 0
// rustc-flags: -C panic=abort -C default-linker-libraries

#![no_std]
#![no_main]
#![feature(core_intrinsics)]
#![allow(internal_features)]

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

use core::cell::UnsafeCell;

struct Point {
    x: i32,
    y: i64,
}

struct Node {
    value: u32,
    next: *const Node,
}

// A raw pointer is not `Sync`, and a static has to be.
unsafe impl Sync for Node {}

struct Shared(UnsafeCell<u32>);

unsafe impl Sync for Shared {}

struct Named {
    weight: &'static u64,
    id: u32,
    scale: u64,
}

static LIMIT: u32 = 40;
static mut CALLS: u64 = 0;
static PRIMES: [u16; 5] = [2, 3, 5, 7, 11];
static ORIGIN: Point = Point { x: -3, y: 9 };
// A pointer to memory without a name.
static FAR: &Point = &Point { x: 100, y: -200 };
// A pointer to another static, and one into the middle of one.
static LIMIT_REF: &u32 = &LIMIT;
static THIRD_PRIME: &u16 = &PRIMES[2];
// Two statics that point at each other.
static FIRST: Node = Node { value: 1, next: &raw const SECOND };
static SECOND: Node = Node { value: 2, next: &raw const FIRST };
static OPERATIONS: [fn(i32) -> i32; 2] = [double, negate];
// Immutable to the language, written through the cell.
static SHARED: Shared = Shared(UnsafeCell::new(5));
static mut BUFFER: [u8; 16] = [0; 16];
static mut CURSOR: *mut u8 = unsafe { (&raw mut BUFFER).cast::<u8>().add(4) };
static EMPTY: () = ();
// Memory without a name that is written: it may be neither read-only nor shared with memory that looks the same.
static mut SCRATCH: &mut [u8; 4] = &mut [1, 2, 3, 4];
static mut SPARE: &mut [u8; 4] = &mut [1, 2, 3, 4];

#[unsafe(no_mangle)]
pub static EXPORTED: i32 = 77;
#[unsafe(no_mangle)]
pub static mut EXPORTED_COUNT: u8 = 250;

const DEFAULT: &Point = &Point { x: 5, y: 6 };
const PAIR: (&u32, u8) = (&7, 1);
const NAMED: Named = Named { weight: &1000, id: 3, scale: 2 };

fn double(n: i32) -> i32 {
    n * 2
}

fn negate(n: i32) -> i32 {
    -n
}

#[inline(never)]
fn limit() -> u32 {
    LIMIT
}

#[inline(never)]
fn count_call() -> u64 {
    unsafe {
        CALLS += 1;
        CALLS
    }
}

#[inline(never)]
fn prime(index: usize) -> u16 {
    PRIMES[index]
}

#[inline(never)]
fn origin() -> &'static Point {
    &ORIGIN
}

#[inline(never)]
fn walk(from: &Node, steps: u32) -> u32 {
    let mut node = from as *const Node;
    let mut step = 0;
    while step < steps {
        node = unsafe { (*node).next };
        step += 1;
    }
    unsafe { (*node).value }
}

#[inline(never)]
fn apply(which: usize, n: i32) -> i32 {
    OPERATIONS[which](n)
}

#[inline(never)]
fn bump_shared() -> u32 {
    unsafe {
        *SHARED.0.get() += 1;
        *SHARED.0.get()
    }
}

#[inline(never)]
fn push(byte: u8) {
    unsafe {
        *CURSOR = byte;
        CURSOR = core::intrinsics::offset(CURSOR, 1usize);
    }
}

#[inline(never)]
fn scratch(index: usize, byte: u8) -> u8 {
    unsafe {
        let kept = SCRATCH[index];
        SCRATCH[index] = byte;
        kept
    }
}

#[inline(never)]
fn spare(index: usize) -> u8 {
    unsafe { SPARE[index] }
}

#[inline(never)]
fn named() -> Named {
    NAMED
}

#[inline(never)]
fn weigh(named: &Named) -> u64 {
    *named.weight * named.scale + named.id as u64
}

#[inline(never)]
fn unit() -> &'static () {
    &EMPTY
}

#[unsafe(no_mangle)]
pub extern "C" fn main(one: i32, _arguments: *const *const u8) -> i32 {
    if limit() != 40 {
        return 1;
    }
    if count_call() != 1 || count_call() != 2 || count_call() != 3 {
        return 2;
    }
    if prime(one as usize) != 3 || prime(4) != 11 {
        return 3;
    }
    let origin = origin();
    if origin.x != -3 || origin.y != 9 {
        return 4;
    }
    if FAR.x != 100 || FAR.y != -200 {
        return 5;
    }
    if *LIMIT_REF != 40 || LIMIT_REF as *const u32 != &raw const LIMIT {
        return 6;
    }
    if *THIRD_PRIME != 5 || THIRD_PRIME as *const u16 != &raw const PRIMES[2] {
        return 7;
    }
    if walk(&FIRST, 0) != 1 || walk(&FIRST, 1) != 2 || walk(&SECOND, 5) != 1 {
        return 8;
    }
    if apply(0, 21) != 42 || apply(one as usize, 21) != -21 {
        return 9;
    }
    if bump_shared() != 6 || bump_shared() != 7 {
        return 10;
    }
    push(9);
    push(8);
    let buffer = unsafe { *(&raw const BUFFER) };
    if buffer[3] != 0 || buffer[4] != 9 || buffer[5] != 8 || buffer[6] != 0 {
        return 11;
    }
    if EXPORTED != 77 {
        return 12;
    }
    unsafe {
        EXPORTED_COUNT += 5;
        if EXPORTED_COUNT != 255 {
            return 13;
        }
    }
    if DEFAULT.x != 5 || DEFAULT.y != 6 {
        return 14;
    }
    let pair = PAIR;
    if *pair.0 != 7 || pair.1 != 1 {
        return 15;
    }
    let named = named();
    if weigh(&named) != 2003 || weigh(&NAMED) != 2003 {
        return 16;
    }
    if unit() as *const () != &raw const EMPTY {
        return 17;
    }
    if scratch(1, 9) != 2 || scratch(1, 0) != 9 || scratch(3, 0) != 4 || spare(1) != 2 || spare(3) != 4 {
        return 18;
    }
    0
}
