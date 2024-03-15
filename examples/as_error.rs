extern crate colored_rs;

use colored_rs::Colorize;
use std::error::Error;

fn main() -> Result<(), Box<dyn Error>> {
    Err("ERROR".red())?
}
