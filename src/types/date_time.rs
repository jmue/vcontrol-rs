use std::convert::TryInto;
use std::fmt;
use std::str::FromStr;

use chrono::{NaiveDate, NaiveDateTime, Datelike, Timelike};
#[cfg(feature = "impl_json_schema")]
use schemars::JsonSchema;
use serde::ser::{Serialize, Serializer};
use serde::de::{self, Deserialize, Deserializer};

#[inline]
fn byte_to_dec(byte: u8) -> u8 {
  byte / 16 * 10 + byte % 16
}

#[inline]
fn dec_to_byte(dec: u8) -> u8 {
  dec / 10 * 16 + dec % 10
}

#[derive(Clone)]
pub struct DateTime([u8; 8]);

impl DateTime {
  pub fn new(year: u16, month: u8, day: u8, hour: u8, minute: u8, second: u8) -> DateTime {
    NaiveDate::from_ymd(year.into(), month.into(), day.into()).and_hms(hour.into(), minute.into(), second.into()).into()
  }

  pub fn year(&self) -> u16 {
    u16::from(byte_to_dec(self.0[0])) * 100 + u16::from(byte_to_dec(self.0[1]))
  }

  pub fn month(&self) -> u8 {
    byte_to_dec(self.0[2])
  }

  pub fn day(&self) -> u8 {
    byte_to_dec(self.0[3])
  }

  pub fn weekday(&self) -> u8 {
    self.0[4]
  }

  pub fn hour(&self) -> u8 {
    byte_to_dec(self.0[5])
  }

  pub fn minute(&self) -> u8 {
    byte_to_dec(self.0[6])
  }

  pub fn second(&self) -> u8 {
    byte_to_dec(self.0[7])
  }

  pub fn from_bytes(bytes: &[u8]) -> Self {
    Self(bytes[..8].try_into().unwrap())
  }

  pub fn to_bytes(&self) -> [u8; 8] {
    self.0
  }
}

impl From<DateTime> for NaiveDateTime {
  fn from(date_time: DateTime) -> NaiveDateTime {
    NaiveDate::from_ymd(
      date_time.year().into(),
      date_time.month().into(),
      date_time.day().into(),
    ).and_hms(
      date_time.hour().into(),
      date_time.minute().into(),
      date_time.second().into(),
    )
  }
}

impl From<NaiveDateTime> for DateTime {
  fn from(date_time: NaiveDateTime) -> DateTime {
    DateTime([
      dec_to_byte((date_time.year() / 100) as u8),
      dec_to_byte((date_time.year() % 100) as u8),
      dec_to_byte(date_time.month() as u8),
      dec_to_byte(date_time.day() as u8),
      date_time.weekday().number_from_monday() as u8,
      dec_to_byte(date_time.hour() as u8),
      dec_to_byte(date_time.minute() as u8),
      dec_to_byte(date_time.second() as u8),
    ])
  }
}

impl FromStr for DateTime {
  type Err = chrono::format::ParseError;

  fn from_str(s: &str) -> Result<DateTime, Self::Err> {
    NaiveDateTime::from_str(s).map(Into::into)
  }
}

impl<'de> Deserialize<'de> for DateTime {
  fn deserialize<D>(deserializer: D) -> Result<DateTime, D::Error>
  where
      D: Deserializer<'de>,
  {
    let string = String::deserialize(deserializer)?;
    DateTime::from_str(&string).map_err(de::Error::custom)
  }
}

#[cfg(feature = "impl_json_schema")]
impl JsonSchema for DateTime {
  fn schema_name() -> String {
    "DateTime".into()
  }

  fn json_schema(gen: &mut schemars::gen::SchemaGenerator) -> schemars::schema::Schema {
    let mut schema = gen.subschema_for::<String>().into_object();
    schema.format = Some("date-time".into());
    schema.into()
  }
}

impl Serialize for DateTime {
  fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
    serializer.serialize_str(&self.to_string())
  }
}

impl fmt::Display for DateTime {
  fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
    write!(f, "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}",
      self.year(),
      self.month(),
      self.day(),
      self.hour(),
      self.minute(),
      self.second(),
    )
  }
}

impl fmt::Debug for DateTime {
  fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
    write!(f, "DateTime(")?;
    fmt::Display::fmt(self, f)?;
    write!(f, ")")
  }
}

#[cfg(test)]
mod tests {
  use super::*;

  #[test]
  fn new() {
    let time = DateTime::new(2018, 12, 23, 17, 49, 31);

    assert_eq!(time.year(), 2018);
    assert_eq!(time.month(), 12);
    assert_eq!(time.day(), 23);
    assert_eq!(time.weekday(), 7);
    assert_eq!(time.hour(), 17);
    assert_eq!(time.minute(), 49);
    assert_eq!(time.second(), 31);
  }

  #[test]
  fn from_str() {
    let time = DateTime::from_str("2018-12-23T17:49:31").unwrap();

    assert_eq!(time.year(), 2018);
    assert_eq!(time.month(), 12);
    assert_eq!(time.day(), 23);
    assert_eq!(time.weekday(), 7);
    assert_eq!(time.hour(), 17);
    assert_eq!(time.minute(), 49);
    assert_eq!(time.second(), 31);
  }

  #[test]
  fn from_bytes() {
    let time = DateTime::from_bytes(&[0x20, 0x18, 0x12, 0x23, 0x07, 0x17, 0x49, 0x31]);

    assert_eq!(time.year(), 2018);
    assert_eq!(time.month(), 12);
    assert_eq!(time.day(), 23);
    assert_eq!(time.weekday(), 7);
    assert_eq!(time.hour(), 17);
    assert_eq!(time.minute(), 49);
    assert_eq!(time.second(), 31);
  }

  #[test]
  fn to_bytes() {
    let time = DateTime::new(2018, 12, 23, 17, 49, 31);
    assert_eq!(time.to_bytes(), [0x20, 0x18, 0x12, 0x23, 0x07, 0x17, 0x49, 0x31]);
  }
}
