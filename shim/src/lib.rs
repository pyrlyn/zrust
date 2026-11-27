//! The rustc codegen backend of ZRust: the only Rust code in the project.
//!
//! It stays thin on purpose. rustc loads this dylib through `-Zcodegen-backend`;
//! real code generation happens in the Zig `zrust-codegen` process.

#![feature(rustc_private)]

// Nothing here uses it by name yet, but the dylib must link against rustc's own
// driver library to resolve compiler symbols once rustc loads it.
extern crate rustc_driver;
