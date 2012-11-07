

Introduction and Goals
----

The goal of  ioh.sh is to measure both the throughput and latency of the different code layers when using NFS mounts on a ZFS appliance.  The ZFS appliance code layers looked with the script are I/O from the disks, ZFS layer and the NFS layer. For each of these layers the script measures the throughput, latency and average I/O size. Some of the layers are further broken down into other layers. For example NFS writes are broken down in to data sync, file sync and non-sync operations and NFS reads are broken down into cached data reads and reads that have to go to disk.

The primary three questions ioh is used to answer are

* Is I/O latency from the I/O subsystem to ZFS appliance sufficiently fast? 
* Is NFS latency from ZFS appliance to the VDB sufficiently fast? 
* Is ZFS adding unusual latency 

__One__: If the latency from the I/O subsystem is not adequate then look into supplying better performing I/O subsystem for ZFS appliance. For example if the goal is 3ms write times per 1K redo write but the underlying I/O subsystem is taking 6ms, then it will be impossible for ZFS appliance to meet those expectations.

__Two__: If the latency for NFS response from ZFS appliance is adequate and yet the NFS client reports latencies as much slower (more than 2ms slower) then one should look instead a problems in the NIC, network or NFS client host, see network  tracing. 

__Three__: If the I/O latency is sufficiently fast but ZFS latency is slow, then this could indicate a problem in the ZFS layer. 

The answer to the question "what is adequate I/O latency" depends. In general a single random 8 Kb block read on Oracle is expected to take 3-12 ms on average, thus the typical latency is around 7.5 ms. 
NOTE: when measuring I/O latency on the source system it's important to use a tool like "iostat" that will show the actually I/Os to the subsystem. The I/O measured by the Oracle database will include both I/Os satisfied from the host file system cache as well as the I/O subsystem unless the database is running with direct I/O 

The ioh tool can also give insight into other useful information such as

* Are IOPs getting near the supported IOPs of the underlying I/O subsystem
* is NFS throughput getting near the maximum bandwidth of the NIC?"

For example if the NIC is 1GbE then the maximum bandwidth is about 115MB/s, and generally 100MB/s is a good rule of thumb for the max.  If throughput is consistently near the NIC maximum, then demand is probably going above maximum and thus increasing latency



	$ ioh.sh -h
	
	usage: ./ioh.sh options
	
	collects I/O related dtrace information into file "ioh.out"
	and displays the
	
	OPTIONS:
	  -h              Show this message
	  -t  seconds     runtime in seconds, defaults to forever
	  -c  seconds     cycle time ie time between collections, defaults to 1 second
	  -f  filename    change the output file name [defautls to ioh.out]
	  -p              parse the data from output file only,  don't run collection
	  -d  display     optional extra data to show: [hist|histsz|histszw|topfile|all]
	                    hist    - latency histogram for NFS,ZFS and IO both reads and writes
	                    histsz  - latency histogram by size for NFS reads
	                    histszw - latency histogram by size for NFS writes
	                    topfile - top files accessed by NFS
	                    all     - all the above options
	                  example
	                    ioh.sh -d "histsz topfile"


two optional environment variables
CWIDTH - histogram column width
PAD - character between columns in the histograms, null by default

Running 

	$ sudo ./ioh.sh 

Outputs to the screen and put raw output into default file name "ioh.out.[date]".
The default output file name can be changed with "-o filename" option.
the raw output can later be formatted with 

	$ ./ioh.sh -p  ioh.out.2012_10_30_10:49:27

By default it will look for "ioh.out". If the raw data is in a different file name it can be specified with "-o filename"

The output looks like

	date: 1335282287 , 24/3/2012 15:44:47
	TCP out:  8.107 MB/s, in:  5.239 MB/s, retrans:        MB/s  ip discards:
	----------------
	            |       MB/s|    avg_ms| avg_sz_kb|     count
	------------|-----------|----------|----------|--------------------
	R |      io:|     0.005 |    24.01 |    4.899 |        1
	R |     zfs:|     7.916 |     0.05 |    7.947 |     1020
	C |   nfs_c:|           |          |          |        .
	R |     nfs:|     7.916 |     0.09 |    8.017 |     1011
	- 
	W |      io:|     9.921 |    11.26 |   32.562 |      312
	W | zfssync:|     5.246 |    19.81 |   11.405 |      471
	W |     zfs:|     0.001 |     0.05 |    0.199 |        3
	W |     nfs:|           |          |          |        .
	W |nfssyncD:|     5.215 |    19.94 |   11.410 |      468
	W |nfssyncF:|     0.031 |    11.48 |   16.000 |        2

The sections are broken down into

* Header with date and TCP throughput
* Reads
* Writes

Reads and Writes are are further broken down into 

* io
* zfs
* nfs

For writes, the non stable storage writes are separated from the writes to stable storage which are marked as "sync" writes. For NFS the sync writes are further broken down into "data" and "file" sync writes.

examples:

The following will refresh the display every 10 seconds and display an extra four sections of data 

	$ sudo ./ioh.sh -c 10 -d "hist histsz histszw topfile"   
	
	date: 1335282287 , 24/3/2012 15:44:47
	TCP out:  8.107 MB/s, in:  5.239 MB/s, retrans:        MB/s  ip discards:
	----------------
	            |       MB/s|    avg_ms| avg_sz_kb|     count
	------------|-----------|----------|----------|--------------------
	R |      io:|     0.005 |    24.01 |    4.899 |        1
	R |     zfs:|     7.916 |     0.05 |    7.947 |     1020
	R |     nfs:|     7.916 |     0.09 |    8.017 |     1011
	- 
	W |      io:|     9.921 |    11.26 |   32.562 |      312
	W | zfssync:|     5.246 |    19.81 |   11.405 |      471
	W |     zfs:|     0.001 |     0.05 |    0.199 |        3
	W |     nfs:|           |                     |        .
	W |nfssyncD:|     5.215 |    19.94 |   11.410 |      468
	W |nfssyncF:|     0.031 |    11.48 |   16.000 |        2
	---- histograms  -------
	    area r_w   32u   64u   .1m   .2m   .5m    1m    2m    4m    8m   16m   33m   65m    .1s   .3s   .5s    1s    2s    2s+
	R        io      .     .     .     .     .     .     .     .     .     1     3     1
	R       zfs   4743   287    44    16     4     3     .     .     .     1     2     2
	R       nfs      .  2913  2028    89    17     3     .     .     .     1     2     2
	-
	W        io      .     .     .    58   249   236    50    63   161   381   261    84    20     1
	W       zfs      3    12     2
	W   zfssync      .     .     .     .    26   162   258   129   228   562   636   250    75    29
	W       nfs      .     .     .     .    12   164   265   134   222   567   637   250    75    29
	--- NFS latency by size ---------
	    ms   size_kb
	R   0.1    8     .  2909  2023    87    17     3     .     .     .     1     2     2
	R   0.1   16     .     4     5     2
	-
	W   5.0    4     .     .     .     .     8    49    10     3     4    11     4     2     1
	W  21.4    8     .     .     .     .     4    55   196    99   152   414   490   199    60    23
	W  18.3   16     .     .     .     .     .    34    29    25    43    91    84    28     8     5
	W  16.1   32     .     .     .     .     .    19    16     7    14    38    36    15     3
	W  19.3   64     .     .     .     .     .     6    11     .     9    11    19     6     2     1
	W  20.4  128     .     .     .     .     .     1     3     .     .     2     4     .     1
	---- top files ----
	   MB/s                  IP  PORT filename
	W  0.01MB/s  172.16.103.196 52482 /domain0/group0/vdb17/datafile/home/oracle/oradata/swingb/control01.ora
	W  0.02MB/s   172.16.100.81 21763 /domain0/group0/vdb16/datafile/export/home/oradata/sol/control01.ora
	W  0.57MB/s   172.16.100.81 21763 /domain0/group0/vdb16/datafile/export/home/oradata/sol/undo.dbf
	W  0.70MB/s   172.16.100.81 21763 /domain0/group0/vdb16/datafile/export/home/oradata/sol/redo3.log
	W  3.93MB/s   172.16.100.81 21763 /domain0/group0/vdb16/datafile/export/home/opt/app/10.2.0.4/db_1/dbs/soe.dbf
	-
	R  0.01MB/s  172.16.100.102 39938 /domain0/group0/vdb12/datafile/home/oracle/oradata/kyle/control01.ora
	R  0.01MB/s  172.16.103.196 52482 /domain0/group0/vdb17/datafile/home/oracle/oradata/swingb/control01.ora
	R  0.02MB/s   172.16.100.81 21763 /domain0/group0/vdb16/datafile/export/home/oradata/sol/control01.ora
	R  0.05MB/s   172.16.100.81 21763 /domain0/group0/vdb16/datafile/export/home/oradata/sol/undo.dbf
	R  7.84MB/s   172.16.100.81 21763 /domain0/group0/vdb16/datafile/export/home/opt/app/10.2.0.4/db_1/dbs/soe.dbf
	IOPs         313


Sections
--------------

First line is the date
Second line is TCP MB per second in,out  and retransmitted.  The last value is "ip discards"

The three parts are all related and are a drill down starting with course grain data at the top to finer grain data at the bottom.

* averages  - default 
* histograms [hist]
* histograms by size reads [histsz]   writes [histszw]   for NFS

The first section is a quick overview.

The second section breaks out the latency into a histogram so one can get an indication of amount of I/O from memory (ie those in microsecond ranges) as well as how far out the outliers are. (are the outliers on the VDBs matching up to the outliers seen on ZFS appliance?)

The third section differentiates between latency of single block random (typically the 8K size) and latency of multi-block sequential reads (32K and higher). The differentiation is important when comparing to Oracle stats which are grouped by single block random reads (called "db file sequential read" ) and sequential multi-block read (called "db file scattered read").

The final section

top files read and write [topfile]
 
is sort of a sanity check as there are periods where there is suppose to be little to no NFS I/O and yet there is, so the top file sections tells which file and which host the NFS I/O is coming from.

The last line after all the sections is total IOPs for reads plus writes.  (Note these IOPs could get converted to higher values at the storage layer if using RAID5 which will cause each write to be two reads plus two writes.)

The first section, shows up by default. The other sections require command line arguments. 

To see just the first section, which is the default, run ioh.sh without any arguments:

	sudo ./ioh.sh

To show non-default sections, add them to the command line

	sudo ./ioh.sh -d "hist histsz histszw topfile"

A shortcut for all sections is "all"  

	sudo ./ioh.sh  -d all

Collecting in the background

	nohup sudo ./ioh.sh -c 60 -t 86400 &

Runs the collection for 1 day (86400 seconds) collecting every 60 seconds and put raw output into default file name "ioh.out".
The default output file name can be changed with "-o filename" option.

__1. Averages:__

The displays I/O, ZFS and NFS data for both reads and writes. The data is grouped to try and help easily correlate these different layers
First line is date in epoch format 

columns

* MB/s - MB transferred a second
* avg_ms - average operation time
* avg_sz_kb - average operation size in kb 
* count - number of operations

example 

	.
	             |      MB/s|     mx_ms| avg_sz_kb|     count
	 ------------|----------|----------|----------|--------------------
	 R |      io:|  through | average  |  average |      count of operations
	 R |     zfs:|  put     |latency   | I/O size | 
	 R |     nfs:|          |millisec  | in KB    |   
	 - 
	 W |      io:|          |          |          |
	 W | zfssync:|          |          |          |                                         
	 W |     zfs:|          |          |          |                                         
	 W |     nfs:|          |          |          |                                         
	 W |nfssyncD:|          |          |          |                                         
	 W |nfssyncF:|          |          |          |                                         


For writes

* zfssync - these are synchronous writes. THese should mainly be Oracle redo writes.
* nfs - unstable storage writes
* nfssyncD - data sync writes
* nfssyncF - file sync writes

DTrace probes used

* io:::start/done check for read or write
* nfs:::op-read-start/op-read-done , nfs:::op-write-start/op-write-done
* zfs_read:entry/return, zfs_write:entry/return

__2. Histograms__

latency distribution for i/o, zfs, nfs for reads and writes. These distributions are not normalized by time, ie if ioh.d is outputs once a second then these counts will be equal to the counts in the first section. If ioh.d outputs every 10 seconds, then these values will be 10x higher

3. Histograms by size for reads and writes

The first column is the average latency for the size of I/O for this line. The second column is the size. The size includes this size and every size lower up till the previous bucket.
The goal here is to show the sizes of I/Os and the different latency for different sizes. For an Oralce database with 8k block size, 8k reads will tend to be random where as higher read sizes say  will be multiblock requests and represent sequential reads. It's common to see the 8K reads running slower than the larger reads.

__4. Top files__

shows the top 5 files for reads and writes. First column is MB/s, then R or W, then IP, then port then filename


Examples and Usage


Idle system

First thing to look at is the MB in and out which answers

*  "how busy is the system?" 
*  "is NFS throughput approaching the limits of the NIC?"

In the following example, there is only less than 50KB/s total NFS throughput ( in plus out) thus the system isn't doing much, and there must be no database activity other than the regular maintenance processes which are always running on a database.
To confirm this, one can look at the top files at the bottom and see that the only activity is on the control files which are read and written to as part of database system maintenance. Otherwise there is no activity to speak of, so no reason look at I/O latency in this case. 
Additionally, all majority of what little I/O is in 16K sizes which is typical of control file activity, where as the default database data block activity is in 8K sizes.
Most read I/O is coming from ZFS appliance cache as its 64 micro seconds.


	date: 1335282646 , 24/3/2012 15:50:46
	TCP  out:  0.016 MB/s, in:  0.030 MB/s, retrans:        MB/s  ip discards:
	----------------
	            |       MB/s|    avg_ms| avg_sz_kb|     count
	------------|-----------|----------|----------|--------------------
	R |      io:|           |          |          |        .
	R |     zfs:|     0.016 |     0.01 |    1.298 |       13
	R |     nfs:|     0.016 |     0.10 |   16.000 |        1
	- 
	W |      io:|     0.365 |     4.59 |    9.590 |       39
	W | zfssync:|     0.031 |    14.49 |   16.000 |        2
	W |     zfs:|     0.001 |     0.07 |    0.199 |        3
	W |     nfs:|           |          |          |        .
	W |nfssyncD:|     0.003 |          |          |        .
	W |nfssyncF:|     0.028 |    14.33 |   14.400 |        2
	---- histograms  -------
	    area r_w   32u   64u   .1m   .2m   .5m    1m    2m    4m    8m   16m   33m   65m    .1s   .3s   .5s    .5s+
	R        io      .
	R       zfs     60     5
	R       nfs      .     .     5
	-
	W        io      .     .     .    20    43    60    11    11     8    28    17     1
	W       zfs      2     8     5     2
	W   zfssync      .     .     .     .     .     .     2     .     2     5     1     1
	W       nfs      .     .     .     .     .     .     2     .     2     5     1     1
	--- NFS latency by size ---------
	    ms   size_kb
	R   0.1   16     .     .     5
	-
	W          8     .     .     .     .     .     .     .     .     .     1     .     1
	W  16.0   16     .     .     .     .     .     .     2     .     2     4     1
	---- top files ----
	   MB/s                  IP  PORT filename
	W  0.00MB/s   172.16.100.81 21763 /domain0/group0/vdb16/datafile/export/home/oradata/sol/control01.ora
	W  0.01MB/s  172.16.100.102 39938 /domain0/group0/vdb12/datafile/home/oracle/oradata/kyle/control01.ora
	W  0.01MB/s  172.16.103.133 59394 /domain0/group0/vdb13/datafile/home/oracle/oradata/kyle/control01.ora
	W  0.01MB/s   172.16.100.69 39682 /domain0/group0/vdb14/datafile/home/oracle/oradata/kyle/control01.ora
	W  0.01MB/s  172.16.103.196 52482 /domain0/group0/vdb17/datafile/home/oracle/oradata/swingb/control01.ora
	-
	R  0.00MB/s   172.16.100.81 21763 /domain0/group0/vdb16/datafile/export/home/oradata/sol/control01.ora
	R  0.01MB/s  172.16.100.102 39938 /domain0/group0/vdb12/datafile/home/oracle/oradata/kyle/control01.ora
	R  0.01MB/s  172.16.103.196 52482 /domain0/group0/vdb17/datafile/home/oracle/oradata/swingb/control01.ora
	IOPs          39


__Active System__
Below is an example of an active system.
Looking at TCP bytes in and out, there is a fair bit 3MB/s out and 2MB/s in. These rates are a long way from saturating 1GbE but there is activity going on.

__READs__
all reads are coming out of the cache. How do we know? For one the average ms latency is 0.07, or 70 micro seconds. Does thhis 70us include slower reads that might be off disk? Looking at the histogram, one can see that the slowest zfs I/O is under 100us and looking just above at the I/O histogram there are no I/Os thus all the I/O is coming from cache.

__Writes__
Writes are pretty slow. Oracle Redo writes on good systems are typically 3ms or liess for small redo. Unfortunately most of the I/O is coming from datafile writes so it's difficult to tell what the redo write times are. (maybe worth enhancing ioh.d to show average latency by file)
Typically the redo does "nfssyncD" writes and datafile writes are simply unstable storage writes "nfs" writes that get sync at a later date. This particular database is using the Oracle parameter "filesystemio_options=setall" which implements direct I/O. Direct I/O can work without sync writes but the implementation depends on the OS. This O/S implementation, OpenSolaris, causes all Direct I/O writes to by sync writes.



	date: 1335284387 , 24/3/2012 16:19:47
	TCP out:  3.469 MB/s, in:  2.185 MB/s, retrans:        MB/s  ip discards:
	----------------
	            ||         |           |          |          o       MB/s|    avg_ms| avg_sz_kb|     count
	------------|-----------|----------|----------|--------------------
	R |      io:|           |          |          |        .
	R |     zfs:|     3.387 |     0.03 |    7.793 |      445
	R |     nfs:|     3.384 |     0.07 |    8.022 |      432
	- 
	W |      io:|     4.821 |    12.08 |   24.198 |      204
	W | zfssync:|     1.935 |    38.50 |   11.385 |      174
	W |     zfs:|     0.001 |     0.06 |    0.199 |        3
	W |     nfs:|           |          |          |        .
	W |nfssyncD:|     1.906 |    39.06 |   11.416 |      171
	W |nfssyncF:|     0.028 |    14.59 |   14.400 |        2
	---- histograms  -------
	    area r_w   64u   .1m   .2m   .5m    1m    2m    4m    8m   16m   33m   65m    .1s   .3s   .3s+
	R        io      .
	R       zfs   2185    34     5     .     1
	R       nfs    903  1201    47     8     1
	-
	W        io      .     .    19   142   143    46    42   108   240   212    57    12     1
	W       zfs     13     3     1
	W   zfssync      .     .     .     .    10     6     .    21    60   384   287    86    16
	W       nfs      .     .     .     .    10     5     .    21    60   384   287    86    16
	--- NFS latency by size ---------
	    ms   size_kb
	R   0.1    8   900  1199    47     7     1
	R   0.1   16     3     2     .     1
	-
	W  17.7    4     .     .     .     .     3     1     .     2     5     3     3
	W  41.1    8     .     .     .     .     3     .     .    13    35   292   231    76    13
	W  34.0   16     .     .     .     .     3     3     .     4    13    61    30     8     2
	W  39.0   32     .     .     .     .     .     1     .     .     2    16    14     2     1
	W  28.3   64     .     .     .     .     1     .     .     .     2     9     8
	W  26.2  128     .     .     .     .     .     .     .     2     3     2     1
	W        256     .     .     .     .     .     .     .     .     .     1
	---- top files ----
	   MB/s             IP  PORT filename
	R  0.01   172.16.100.81 21763 /domain0/group0/vdb16/datafile/export/home/oradata/sol/control01.ora
	R  0.01  172.16.103.196 52482 /domain0/group0/vdb17/datafile/home/oracle/oradata/swingb/control01.ora
	R  0.02   172.16.100.81 21763 /domain0/group0/vdb16/datafile/export/home/oradata/sol/system.dbf
	R  0.02   172.16.100.81 21763 /domain0/group0/vdb16/datafile/export/home/oradata/sol/undo.dbf
	R  3.33   172.16.100.81 21763 /domain0/group0/vdb16/datafile/export/home/opt/app/product/dbs/soe.dbf 
	-
	W  0.01   172.16.100.81 21763 /domain0/group0/vdb16/datafile/export/home/oradata/sol/control01.ora
	W  0.01  172.16.103.196 52482 /domain0/group0/vdb17/datafile/home/oracle/oradata/swingb/control01.ora
	W  0.15   172.16.100.81 21763 /domain0/group0/vdb16/datafile/export/home/oradata/sol/undo.dbf
	W  0.30   172.16.100.81 21763 /domain0/group0/vdb16/datafile/export/home/oradata/sol/redo1.log
	W  1.46   172.16.100.81 21763 /domain0/group0/vdb16/datafile/export/home/opt/app/product/dbs/soe.dbf 
	IOPs         204

ZFS read layer problem

	          |      MB/s|    avg_ms|  avg_sz_kb
	----------|----------|----------|-----------
	R |   io :|    88.480|      4.60|     17.648 
	R |  zfs :|    19.740|      8.51|     12.689 
	R |  nfs :|    16.562|     22.67|     30.394 

In this case the ZFS I/O 19MB/s is higher than NFS at 16MB/s. Now that could because some thing is accessing the file system locally on ZFS appliance or that ZFS is doing read ahead, so there are possible explanations, but it's interesting. Second subsystem I/O at 88MB/s is much greater than ZFS I/O at 19MB/s. Again that is notable. Could because there is a scrub going on. (to check for a scrub, run "spool status", to turn off scrub run "zpool scrub -s domain0" though the scrub has to be run at some point). Both interesting observations.

Now the more interesting parts. The NFS response time 22ms is almost 3x the average ZFS response time 8ms. On the other hand the average size of NFS I/O is 2.5x the average ZFS I/O size so that might be understandable.
The hard part to understand is that the ZFS latency 8ms is twice the latency of subsystem I/O at 4ms yet the average size of the I/O sub-system reads is bigger than the average ZFS read. This doesn't make any sense.

In this case to hone in the data a bit, it would be worth turning off a scrub if it was running and see what the stats are to eliminate a factor that could be muddying the waters.

But in this case, even without a scrub going, the ZFS latency was 2-3x slower than the I/O subsystem latency.

It turns out ZFS wasn't caching and spending a lot of time trying to keep the ARC clean. 

ZFS write layer problem

	           |       MB/s|    avg_ms| avg_sz_kb|     count
	-----------|-----------|----------|----------|--------------------
	W |     io:|     10.921|     23.26|    32.562|       380
	W |    zfs:|    127.001|     37.95|     0.199|      8141
	W |    nfs:|     0.000 |     0.00 |    0.000 |        0

NFS is 0 MB/s because this was from http traffic. 
The current version of ioh would show the TCP MB/s.
This version also mixed up zfs sync and non-sync writes into one bucket, but much of the ZFS writes have to be non-sync because the write rate is 127MB/s where as the I/O subsystem writes are only 10MB/s thus at least 117MB/s is not sync and if they are not sync they are just memory writes so should be blindingly fast, but they aren't. The average latency for the ZFS writes is 37ms. All the more shockingly the average size is only 0.199K  where as the I/O subsystem writes 32K in 23ms.
The case here was that because of disk errors, the ZFS layer was self throttling way to much.  This was a bug

