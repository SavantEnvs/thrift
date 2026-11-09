namespace cpp seed

enum Color {
  RED = 1,
  GREEN = 2,
  BLUE = 3
}

typedef i64 Timestamp

struct Point {
  1: required i32 x,
  2: optional i32 y = 7,
  3: Color color = Color.RED
}

exception Oops {
  1: string message
}

const i32 ANSWER = 42
const string NAME = "thrift"
const bool FLAG = true
const double RATIO = 0.5
const list<i32> PRIMES = [2, 3, 5, 7]
const set<string> WORDS = ["a", "b"]
const map<string, i32> LIMITS = {"lo": 1, "hi": 100}

service Svc {
  Point get(1: i32 id) throws (1: Oops e),
  oneway void ping(),
  list<Point> all()
}
