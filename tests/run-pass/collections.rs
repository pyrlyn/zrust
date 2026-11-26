// expect-stdout: [1, 4, 9]
// expect-stdout: b=2
// expect-stdout: hello, world
// expect-stdout: 3 words
// expect-stdout: caught
// unsupported: needs phase A6 (`std`)

use std::collections::BTreeMap;

#[derive(Debug, Clone, PartialEq)]
struct Point {
    x: i64,
    y: i64,
}

fn squares(limit: u32) -> Vec<u32> {
    let mut out = Vec::new();
    let mut i = 1;
    while i <= limit {
        out.push(i * i);
        i += 1;
    }
    out
}

fn parse(text: &str) -> Result<i64, std::num::ParseIntError> {
    let value: i64 = text.trim().parse()?;
    Ok(value)
}

fn main() {
    println!("{:?}", squares(3));

    let mut map = BTreeMap::new();
    map.insert("a", 1);
    map.insert("b", 2);
    if let Some((key, value)) = map.iter().next_back() {
        println!("{key}={value}");
    }

    let mut text = String::from("hello");
    text.push_str(", world");
    println!("{text}");
    println!("{} words", "one two three".split(' ').count());

    let points = [Point { x: 1, y: 2 }, Point { x: 3, y: 4 }];
    assert_eq!(points[0].clone(), Point { x: 1, y: 2 });
    assert_eq!(points.iter().map(|p| p.x + p.y).sum::<i64>(), 10);

    if parse("nope").is_err() {
        println!("caught");
    }
}
