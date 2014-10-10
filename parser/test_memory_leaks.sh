#!/usr/bin/env bash

cat > test_memory.c <<EOF
#include "query_types.h"

int main(int argc, char **argv) {
  // test freeing on close
  queries q = parse_query("select count(*) from users.events group_by user_email,time(1h) where time>now()-1d;");
  close_queries(&q);

  q = parse_query("explain select users.events group_by user_email,time(1h) where time>now()-1d;");
  close_queries(&q);

  q = parse_query("select * from foo where time < -1s");
  close_queries(&q);

  q = parse_query("select * from merge(/.*/) where time < -1s");
  close_queries(&q);

  // test partial regex
  q = parse_query("list series /");
  close_queries(&q);

  // test freeing list series query
  q = parse_query("list series /foo/ bar");
  close_queries(&q);

  // test freeing on error
  q = parse_query("select count(*) from users.events group_by user_email,time(1h) where time >> now()-1d;");
  close_queries(&q);

  // test freeing alias
  q = parse_query("select count(bar) as the_count from users.events group_by user_email,time(1h);");
  close_queries(&q);

  // test freeing where conditions
  q = parse_query("select value from t where c == 5 and b == 6;");
  close_queries(&q);

  // test freeing where conditions
  q = parse_query("select -1 * value from t where c == 5 and b == 6;");
  close_queries(&q);

  // test freeing simple query
  q = parse_query("select value from t where c == '5';");
  close_queries(&q);

  // test freeing on error
  q = parse_query("select value from t where c = '5';");
  close_queries(&q);

  q = parse_query("select value from cpu.idle where value > 90 and (time > now() - 1d or value > 80) and time < now() - 1w;");
  close_queries(&q);

  q = parse_query("select value from cpu.idle where value > 90 and (time > now() - 1d or value > 80) and time < now() - 1w last 10;");
  close_queries(&q);

  q = parse_query("select email from users.events where email =~ /gmail\\\\.com/i and time>now()-2d;");
  close_queries(&q);

  q = parse_query("select email from users.events as events where email === /gmail\\\\.com/i and time>now()-2d;");
  close_queries(&q);

  q = parse_query("select email from users.events where email in ('jvshahid@gmail.com')");
  close_queries(&q);

  q = parse_query("drop series foobar");
  close_queries(&q);

  q = parse_query("select * from foobar limit");
  close_queries(&q);

  // test continuous queries
  q = parse_query("select * from foo into bar;");
  close_queries(&q);

  q = parse_query("list continuous queries;");
  close_queries(&q);

  q = parse_query("drop continuous query 5;");
  close_queries(&q);

  return 0;
}
EOF
gcc -g *.c
valgrind --error-exitcode=1 --leak-check=full ./a.out
valgrind_result=$?
rm ./a.out test_memory.c
exit $valgrind_result
