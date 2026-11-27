// expect-exit: 0
// rustc-flags: -C panic=abort -C default-linker-libraries

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

struct Point {
    x: i32,
    y: i32,
}

struct View<'a> {
    items: &'a [u32],
    scale: u32,
}

// A struct whose last field has no size of its own: a pointer to it carries the length of that field.
struct Packet<T: ?Sized> {
    id: u32,
    body: T,
}

static TABLE: &[u64] = &[10, 20, 30, 40];

#[inline(never)]
fn sum(values: &[u32]) -> u32 {
    let mut total = 0;
    let mut index = 0;
    while index < values.len() {
        total += values[index];
        index += 1;
    }
    total
}

#[inline(never)]
fn fill(values: &mut [u16], with: u16) {
    let mut index = 0;
    while index < values.len() {
        values[index] = with + index as u16;
        index += 1;
    }
}

#[inline(never)]
fn last(values: &[u8]) -> u8 {
    values[values.len() - 1]
}

#[inline(never)]
fn first_two(values: &[i64]) -> (i64, i64) {
    match values {
        [a, b, ..] => (*a, *b),
        _ => (-1, -1),
    }
}

#[inline(never)]
fn ends(values: &[i64]) -> i64 {
    match values {
        [first, .., last] => *first - *last,
        [only] => *only,
        [] => 0,
    }
}

#[inline(never)]
fn exactly_three(values: &[u8]) -> bool {
    matches!(values, [_, _, _])
}

#[inline(never)]
fn rest(values: &[u32]) -> &[u32] {
    match values {
        [_, rest @ ..] => rest,
        [] => values,
    }
}

#[inline(never)]
fn middle(values: &mut [u32]) -> &mut [u32] {
    match values {
        [_, middle @ .., _] => middle,
        other => other,
    }
}

#[inline(never)]
fn far_corner(points: &[Point]) -> i32 {
    let mut best = 0;
    let mut index = 0;
    while index < points.len() {
        let point = &points[index];
        if point.x + point.y > best {
            best = point.x + point.y;
        }
        index += 1;
    }
    best
}

#[inline(never)]
fn mirror(points: &mut [Point]) {
    let mut index = 0;
    while index < points.len() {
        let kept = points[index].x;
        points[index].x = points[index].y;
        points[index].y = kept;
        index += 1;
    }
}

#[inline(never)]
fn cell(rows: &[[u8; 3]], row: usize, column: usize) -> u8 {
    rows[row][column]
}

#[inline(never)]
fn scaled(view: &View, index: usize) -> u32 {
    view.items[index] * view.scale
}

#[inline(never)]
fn view(items: &[u32], scale: u32) -> View<'_> {
    View { items, scale }
}

#[inline(never)]
fn raw_len(values: *const [u16]) -> usize {
    values.len()
}

#[inline(never)]
fn rebuilt(values: &[u32]) -> *const [u32] {
    core::ptr::slice_from_raw_parts(values.as_ptr(), values.len() - 1)
}

#[inline(never)]
fn as_bytes(values: &[u32]) -> *const [u8] {
    values as *const [u32] as *const [u8]
}

#[inline(never)]
fn count(units: &[()]) -> usize {
    units.len()
}

#[inline(never)]
fn body_sum(packet: &Packet<[u8]>) -> u32 {
    let mut total = packet.id;
    let mut index = 0;
    while index < packet.body.len() {
        total += packet.body[index] as u32;
        index += 1;
    }
    total
}

#[inline(never)]
fn same(a: &[u32], b: &[u32]) -> bool {
    a.as_ptr() == b.as_ptr() && a.len() == b.len()
}

#[unsafe(no_mangle)]
pub extern "C" fn main(one: i32, _arguments: *const *const u8) -> i32 {
    let seed = one as u32;
    let mut numbers = [seed, 2, 3, 4, 5];
    if sum(&numbers) != 15 || sum(&[]) != 0 || sum(&[seed]) != 1 {
        return 1;
    }
    let mut words = [0u16; 6];
    fill(&mut words, 100);
    if words[0] != 100 || words[5] != 105 {
        return 2;
    }
    if last(&[7, 8, 9]) != 9 || last(b"xyz") != b'z' {
        return 3;
    }
    if first_two(&[4, 5, 6]) != (4, 5) || first_two(&[4]) != (-1, -1) {
        return 4;
    }
    if ends(&[10, 20, 3]) != 7 || ends(&[11]) != 11 || ends(&[]) != 0 {
        return 5;
    }
    if !exactly_three(&[1, 2, 3]) || exactly_three(&[1, 2]) || exactly_three(&[1, 2, 3, 4]) {
        return 6;
    }
    let tail = rest(&numbers);
    if tail.len() != 4 || tail[0] != 2 || sum(tail) != 14 || rest(&[]).len() != 0 {
        return 7;
    }
    let inner = middle(&mut numbers);
    if inner.len() != 3 {
        return 8;
    }
    inner[0] = 20;
    inner[2] = 40;
    if numbers[0] != 1 || numbers[1] != 20 || numbers[3] != 40 || numbers[4] != 5 {
        return 9;
    }
    let mut points = [Point { x: 1, y: 2 }, Point { x: 30, y: -4 }, Point { x: 5, y: 6 }];
    if far_corner(&points) != 26 {
        return 10;
    }
    mirror(&mut points);
    if points[1].x != -4 || points[1].y != 30 || points[2].x != 6 {
        return 11;
    }
    let rows = [[1u8, 2, 3], [4, 5, 6]];
    if cell(&rows, 1, 2) != 6 || cell(&rows, 0, one as usize) != 2 {
        return 12;
    }
    let items = [3, 4, 5];
    let view = view(&items, 10);
    if scaled(&view, 2) != 50 || view.items.len() != 3 {
        return 13;
    }
    if raw_len(&raw const words) != 6 {
        return 14;
    }
    let shorter = rebuilt(&items);
    if shorter.len() != 2 || sum(unsafe { &*shorter }) != 7 {
        return 15;
    }
    if as_bytes(&items).len() != 3 {
        return 16;
    }
    if count(&[(), (), ()]) != 3 {
        return 17;
    }
    if TABLE.len() != 4 || TABLE[2] != 30 {
        return 18;
    }
    let packet = Packet { id: 100, body: [1u8, 2, 3] };
    let unsized_packet: &Packet<[u8]> = &packet;
    if body_sum(unsized_packet) != 106 || unsized_packet.body.len() != 3 || unsized_packet.id != 100 {
        return 19;
    }
    if !same(&items, &items) || same(&items, rest(&items)) {
        return 20;
    }
    0
}
