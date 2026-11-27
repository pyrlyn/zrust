// expect-stdout: 3
// expect-stdout: zrust
// expect-stdout: 2
// expect-stdout: 5
// unsupported: needs phase A6 (`std`)

use std::cell::Cell;
use std::sync::atomic::{AtomicU32, Ordering};

static COUNTER: AtomicU32 = AtomicU32::new(1);
static NAME: &str = "zrust";
static TABLE: [&u32; 2] = [&FIRST, &2];
static FIRST: u32 = 1;
const STEP: u32 = 2;

thread_local! {
    static LOCAL: Cell<u32> = const { Cell::new(5) };
}

fn main() {
    COUNTER.fetch_add(STEP, Ordering::Relaxed);
    println!("{}", COUNTER.load(Ordering::Relaxed));
    println!("{NAME}");
    println!("{}", TABLE.len() as u32 * *TABLE[0]);
    println!("{}", LOCAL.with(Cell::get));
}
