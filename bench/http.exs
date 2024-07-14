ping = """
HTTP/1.1 200 OK\r
Date: Fri, 12 Jul 2024 06:39:11 GMT\r
Connection: Keep-Alive\r
Content-Type: text/html; charset=UTF-8\r
Transfer-Encoding: chunked\r
Keep-Alive: timeout=10\r
X-ClickHouse-Summary: {"read_rows":"0","read_bytes":"0","written_rows":"0","written_bytes":"0","total_rows_to_read":"0","result_rows":"0","result_bytes":"0","elapsed_ns":"95583"}\r
\r
3\r
Ok.\r
0\r
\r
"""

numbers_10 = """
HTTP/1.1 200 OK\r
Date: Fri, 12 Jul 2024 06:41:50 GMT\r
Connection: Keep-Alive\r
Content-Type: text/tab-separated-values; charset=UTF-8\r
X-ClickHouse-Server-Display-Name: 97f28e9ea39a\r
Transfer-Encoding: chunked\r
X-ClickHouse-Query-Id: ae44d136-1a32-4397-bd26-09541ef8f5ef\r
X-ClickHouse-Format: TabSeparated\r
X-ClickHouse-Timezone: UTC\r
Keep-Alive: timeout=10\r
X-ClickHouse-Summary: {"read_rows":"10","read_bytes":"80","written_rows":"0","written_bytes":"0","total_rows_to_read":"10","result_rows":"0","result_bytes":"0","elapsed_ns":"9326542"}\r
\r
0
1
2
3
4
5
6
7
8
9
\r
0\r
\r
"""

Benchee.run(%{
  "wip" => fn ->
    nil
  end
})
