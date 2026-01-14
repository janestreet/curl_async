# Curl_async
Provides use of libcurl within Async.

Async is only compatible with a libcurl specially built with the compile-time flag
'--disable-socketpair'. Any libcurl supplied by a package manager (RPM, etc) will probably
not have this flag and will not work with Async. For more information see 'fd_tracker.mli'.

