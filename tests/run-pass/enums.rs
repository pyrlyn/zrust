// expect-stdout: circle 12
// expect-stdout: rect 6
// expect-stdout: none
// expect-stdout: some 7
// expect-stdout: less
// unsupported: needs phase A6 (`std`)

use std::cmp::Ordering;

enum Shape {
    Circle { radius: u32 },
    Rect(u32, u32),
    Empty,
}

fn area(shape: &Shape) -> Option<u32> {
    match shape {
        Shape::Circle { radius } => Some(3 * radius * radius),
        Shape::Rect(w, h) => Some(w * h),
        Shape::Empty => None,
    }
}

// A niche-encoded enum: `None` lives in the null pointer.
fn first(values: &[u32]) -> Option<&u32> {
    values.first()
}

fn main() {
    let shapes = [Shape::Circle { radius: 2 }, Shape::Rect(2, 3), Shape::Empty];
    for shape in &shapes {
        match (shape, area(shape)) {
            (Shape::Circle { .. }, Some(a)) => println!("circle {a}"),
            (Shape::Rect(..), Some(a)) => println!("rect {a}"),
            _ => println!("none"),
        }
    }
    if let Some(value) = first(&[7, 8]) {
        println!("some {value}");
    }
    match 1.cmp(&2) {
        Ordering::Less => println!("less"),
        Ordering::Equal => println!("equal"),
        Ordering::Greater => println!("greater"),
    }
}
