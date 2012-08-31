#!/bin/bash
# Copyright (c) 2012 by Delphix.


# consider adding flags for
#  perl variables
#    $CWIDTH=$ENV{'CWIDTH'}||6;
#    $PAD=$ENV{'PAD'}||"";
#  dtrace variable for IP filtering
#    inline string ADDR=\$\$3;

usage()
{
cat << EOF
usage: $0 options

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
EOF
}

FILENAME="ioh.out"
RUNTIME=-1
CYCLETIME=1
DISPLAY=""

while getopts .hf:d:t:c:p. OPTION
do
     case $OPTION in
         h)
             usage
             exit 1
             ;;
         t)
             RUNTIME=$OPTARG
             ;;
         c)
             CYCLETIME=$OPTARG
             ;;
         d)
             DISPLAY=$OPTARG
             ;;
         f)
             FILENAME=$OPTARG
             ;;
         p)
             PARSE=1
             ;;
         ?)
             usage
             exit
             ;;
     esac
done

echo "RUNTIME=$RUNTIME"
echo "CYCLETIME=$CYCLETIME"
echo "DISPLAY=$DISPLAY"
echo "PARSE=$PARSE"
echo "FILENAME=$FILENAME"


if [ -f ioh.out ]; then
  dt=`date +'%Y_%m_%d_%H:%M:%S'`
  mv ioh.out ioh.out.$dt 
fi

if [[ $PARSE == 1 ]]; then
       cat $FILENAME
else
/usr/sbin/dtrace -C -s /dev/stdin << EOF 
#pragma D option quiet
#pragma D option defaultargs
#pragma D option dynvarsize=16m

#include <sys/file.h>

inline int    TIMER=$CYCLETIME;
inline int    RUNTIME=$RUNTIME;
inline string ADDR=\$\$3;

dtrace:::BEGIN
{
       timerun = 0; 
       ticks = TIMER;
       TITLE=10;
       title = 0;
       COLLECT_TCP=0;
       COLLECT_NFSOPS=0;
       /* www.dtracebook.com/index.php/Application_Level_Protocols:nfsv3syncwrite.d */
	stable_how[0] = "Unstable";
	stable_how[1] = "Data_Sync";
	stable_how[2] = "File_Sync";
	/* See /usr/include/nfs/nfs.h */
}

dtrace:::BEGIN
/ COLLECT_TCP == 0 /
{
       @tcp_ct["R"]=count();
       @tcp_sz["R"]=sum(0);
       @tcp_ct["W"]=count();
       @tcp_sz["W"]=sum(0);
}
dtrace:::BEGIN
/ COLLECT_NFSOPS == 0 /
{
    @nfs_ops_hist["hist_name,","null"]=quantize(0);
}

/* ===================== beg TCP ================================= 
tcp:::send 
/ COLLECT_TCP == 1 && ( ADDR == NULL || args[3]->tcps_raddr == ADDR ) &&  args[2]->ip_plength - args[4]->tcp_offset > 0 / 
{      this->type="R";
       @tcp_ct[this->type]=count();
       @tcp_sz[this->type]=sum(args[2]->ip_plength - args[4]->tcp_offset);
       @tcp_tm[this->type]=max(0);
       @tcprsz=quantize(args[2]->ip_plength - args[4]->tcp_offset);
}
tcp:::receive 
/ COLLECT_TCP == 1 && (ADDR==NULL || args[3]->tcps_raddr==ADDR ) && args[2]->ip_plength-args[4]->tcp_offset > 0 / 
{      this->type="W";
       @tcp_ct[this->type]=count();
       @tcp_sz[this->type]=sum( args[2]->ip_plength - args[4]->tcp_offset);
       @tcp_tm[this->type]=max(0);
       @tcpwsz=quantize(args[2]->ip_plength - args[4]->tcp_offset);
} 
===================== end TCP ================================= */


/* ===================== beg NFS ================================= */
nfsv3:::op-read-start, nfsv3:::op-write-start ,nfsv4:::op-read-start {
		tm[args[0]->ci_remote,args[1]->noi_xid] = timestamp;
		sz[args[0]->ci_remote,args[1]->noi_xid] = args[2]->count    ;
		flag[args[0]->ci_remote,args[1]->noi_xid] = 0;
		self->nfs=1;
}
/* sdt:::arc-miss gives info on direct users of the arc 
 *  if arc-miss, then we do an I/O */

sdt:::arc-miss /self->nfs/ { self->io = 1; self->nfs =0 ;}

nfsv3:::op-write-start {
        flag[args[0]->ci_remote,args[1]->noi_xid] = args[2]->stable;
}
nfsv4:::op-write-start {
        flag[args[0]->ci_remote,args[1]->noi_xid] = args[2]->stable;
	tm[args[0]->ci_remote,args[1]->noi_xid] = timestamp;
	sz[args[0]->ci_remote,args[1]->noi_xid] = args[2]->data_len ;
}
nfsv3:::op-read-done, nfsv3:::op-write-done, nfsv4:::op-read-done, nfsv4:::op-write-done
/tm[args[0]->ci_remote,args[1]->noi_xid]/
{
        this->delta= (timestamp - tm[args[0]->ci_remote,args[1]->noi_xid])/1000;
        this->flag =  flag[args[0]->ci_remote,args[1]->noi_xid];
        this->file =  args[1]->noi_curpath;

        this->type =  probename == "op-write-done" ? "W" : "R";
        /*   self->io ? "uncached" : "cached"  */
        this->type_cache = (probename == "op-write-done") ? "W": self->io ? "R" : "C" ;

    /* ipaddr=ip[args[1]->noi_xid]; */
        this->ipaddr = inet_ntoa(&((struct sockaddr_in *)((struct svc_req *)arg0)->
            rq_xprt->xp_xpc.xpc_rtaddr.buf)->sin_addr.S_un.S_addr);
        this->port = ((struct sockaddr_in *)((struct svc_req *)arg0)->
            rq_xprt->xp_xpc.xpc_rtaddr.buf)->sin_port;

        @nfs_fir["R",this->file,this->ipaddr,this->port]= sum( (this->type == "R" ? sz[args[0]->ci_remote,args[1]->noi_xid] : 0));
        @nfs_fiw["W",this->file,this->ipaddr,this->port]= sum( (this->type == "W" ? sz[args[0]->ci_remote,args[1]->noi_xid] : 0));

        /* store size along with max time so the can be correlated */
        this->overload = ( (this->delta) * (1000*1000*1000) +   sz[args[0]->ci_remote,args[1]->noi_xid]);
        @nfs_mx[this->flag,"R"]=max( (this->type == "R" ? this->overload : 0));
        @nfs_mx[this->flag,"W"]=max( (this->type == "W" ? this->overload : 0));

        @nfs_hist["hist_name,",this->type]=quantize(this->delta);

        this->size = sz[args[0]->ci_remote,args[1]->noi_xid];
        this->buck = ( this->size > 4096 ) ? 8192 : 4096 ;
        this->buck = ( this->size > 8192 ) ?  16384 : this->buck ;
        this->buck = ( this->size > 16384 ) ?  32768 : this->buck ;
        this->buck = ( this->size > 32768 ) ?  65536 : this->buck ;
        this->buck = ( this->size > 65536 ) ?  131072 : this->buck ;
        this->buck = ( this->size > 131072 ) ?  262144 : this->buck ;
        this->buck = ( this->size > 262144 ) ?  524288 : this->buck ;
        this->buck = ( this->size > 524288 ) ?  1048576 : this->buck ;
        @nfs_tmsz["hist_name,",this->buck,this->type]=quantize(this->delta);
        @nfs_avtmsz["nfs_avg_tmsz",this->type,this->buck]=sum(this->delta);
        @nfs_cttmsz["nfs_avg_ctsz",this->type,this->buck]=count();

        @nfs_tm[this->flag,this->type_cache]=sum(this->delta); 
        @nfs_ct[this->flag,this->type_cache]=count();
        @nfs_sz[this->flag,this->type_cache]=sum(sz[args[0]->ci_remote,args[1]->noi_xid]);

	tm[args[0]->ci_remote,args[1]->noi_xid] = 0;
	sz[args[0]->ci_remote,args[1]->noi_xid] = 0;
        flag[args[0]->ci_remote,args[1]->noi_xid]=0;
        self->io = 0;
} 

/*  Collect NFS OPS
    commenting out this section as I've only used it once
    and including it makes script go over default dtrace_dof_maxsize

nfsv3:::op-commit-start, nfsv3:::op-pathconf-start, nfsv3:::op-fsinfo-start, nfsv3:::op-fsstat-start, 
nfsv3:::op-readdirplus-start, nfsv3:::op-readdir-start, nfsv3:::op-link-start, nfsv3:::op-rename-start, 
nfsv3:::op-rmdir-start, nfsv3:::op-remove-start, nfsv3:::op-mknod-start, nfsv3:::op-symlink-start,
nfsv3:::op-mkdir-start, nfsv3:::op-create-start, nfsv3:::op-write-start, nfsv3:::op-read-start, 
nfsv3:::op-readlink-start, nfsv3:::op-access-start, nfsv3:::op-lookup-start, nfsv3:::op-setattr-start, 
nfsv3:::op-getattr-start, nfsv3:::op-null-start {
	tm[args[0]->ci_remote,args[1]->noi_xid] = timestamp;
}
nfsv3:::op-commit-done, nfsv3:::op-pathconf-done, nfsv3:::op-fsinfo-done, nfsv3:::op-fsstat-done, 
nfsv3:::op-readdirplus-done, nfsv3:::op-readdir-done, nfsv3:::op-link-done, nfsv3:::op-rename-done, 
nfsv3:::op-rmdir-done, nfsv3:::op-remove-done, nfsv3:::op-mknod-done, nfsv3:::op-symlink-done,
nfsv3:::op-mkdir-done, nfsv3:::op-create-done, nfsv3:::op-write-done, nfsv3:::op-read-done, 
nfsv3:::op-readlink-done, nfsv3:::op-access-done, nfsv3:::op-lookup-done, nfsv3:::op-setattr-done, 
nfsv3:::op-getattr-done, nfsv3:::op-null-done
/tm[args[0]->ci_remote,args[1]->noi_xid]/
{
        this->delta= (timestamp - tm[args[0]->ci_remote,args[1]->noi_xid])/1000;
        @nfs_ops_hist["hist_name,",probename]=quantize(this->delta);
	tm[args[0]->ci_remote,args[1]->noi_xid] = 0;
} 
*/
/* --------------------- end NFS --------------------------------- */


/* ===================== beg ZFS ================================= */
zfs_read:entry,zfs_write:entry {
         self->ts = timestamp;
         self->filepath = args[0]->v_path;
         self->size = ((uio_t *)arg1)->uio_resid;
}
zfs_read:entry  { self->flag=0; }
zfs_write:entry { self->flag = args[2] & (FRSYNC | FSYNC | FDSYNC) ? 1 : 0; }
zfs_read:return,zfs_write:return /self->ts / {
        this->type =  probefunc == "zfs_write" ? "W" : "R";
        this->delta=(timestamp - self->ts) /1000;

        @zfs_tm[self->flag,this->type]= sum(this->delta);
        @zfs_ct[self->flag,this->type]= count();
        @zfs_sz[self->flag,this->type]= sum(self->size);
        /*      convert time from ns to us , */
        this->overload = ( (this->delta) * (1000*1000*1000) + self -> size );    
        @zfs_mx[self->flag,"R"]=max( (this->type == "R" ? this->overload : 0));
        @zfs_mx[self->flag,"W"]=max( (this->type == "W" ? this->overload : 0));

        @zfs_hist["hist_name,",this->type,self->flag]=quantize(this->delta);

        self->flags=0;
        self->ts=0;
        self->filepath=0;
        self->size=0;
} /* --------------------- end ZFS --------------------------------- */


/* ===================== beg IO ================================= */
io:::start / arg0 != NULL && args[0]->b_addr != 0 / {
       tm_io[args[0]->b_edev, args[0]->b_blkno] = timestamp;
       sz_io[args[0]->b_edev, args[0]->b_blkno] = args[0]->b_bcount;
}

io:::done /tm_io[args[0]->b_edev, args[0]->b_blkno] /
{

       this->type = args[0]->b_flags & B_READ ? "R" : "W" ;
       this->delta = (( timestamp - tm_io[ args[0]->b_edev, args[0]->b_blkno] ))/1000;
       this->size =sz_io[ args[0]->b_edev, args[0]->b_blkno ] ;
       @io_tm[this->type]=sum(this->delta); 
       @io_ct[this->type]=count();
       @io_sz[this->type]=sum(this->size) ;

       this->overload = ( (this->delta) * (1000*1000*1000) + this->size );    
       @io_mx["R"]=max( (this->type == "R" ? this->overload : 0));
       @io_mx["W"]=max( (this->type == "W" ? this->overload : 0));

       tm_io[args[0]->b_edev, args[0]->b_blkno] = 0;
       sz_io[args[0]->b_edev, args[0]->b_blkno] = 0;

       @io_hist["hist_name,",this->type]=quantize(this->delta);
} /* --------------------- end IO --------------------------------- */


/*
doesn't seem to work
mib:::tcp*                  { @tcp[probename] = sum(args[0]); }
*/

/*
mibs of possible interest

mib:::tcpOutAckDelayed      ,
mib:::tcpCurrEstab    ,
mib:::tcpActiveOpens    ,
mib:::tcpAttemptFails   ,
mib:::tcpHalfOpenDrop   ,
mib:::tcpInDataPastWinBytes ,
mib:::tcpInDataUnorderBytes ,
mib:::tcpInErrs         ,
mib:::tcpListenDrop         ,
mib:::tcpListenDropQ0         ,
mib:::tcpTimRetrans     ,
mib:::tcpRetransSegs        ,
mib:::tcpInDupAck           ,
mib:::tcpInDataDupBytes ,
mib:::tcpInDataPartDupBytes,
*/

mib:::tcpInAckBytes     ,
mib:::tcpRetransBytes       ,
mib:::tcpOutDataBytes   ,
mib:::tcpInDataInorderBytes ,
mib:::tcpInDataUnorderBytes { @tcp[probename]  = sum(args[0]); }
mib:::ipIfStatsInDiscards   { @ip[probefunc]  = sum(args[0]); }


profile:::tick-1sec / ticks > 0 / { ticks--; timerun++; }
profile:::tick-1sec / timerun > RUNTIME && RUNTIME != -1  / { exit(0); }


profile:::tick-1sec
/ ticks == 0 /
{
       printf("date,%d\n",walltimestamp);

/* histograms */

       printf("hist_begin,hist_nfs_tmsz\n");
       printa(@nfs_tmsz);
       printf("hist_end,hist_nfs_tmsz\n");

       printf("hist_begin,hist_zfs\n");
       printa(@zfs_hist);
       printf("hist_end,hist_zfs\n");

       printf("hist_begin,hist_nfs\n");
       printa(@nfs_hist);
       printf("hist_end,hist_nfs\n");

       printf("hist_begin,hist_io\n");
       printa(@io_hist);
       printf("hist_end,hist_io\n");


/* histogram end */

       normalize(@nfs_tm,TIMER);
       printa("nfs%d_tm ,%s,%@d\n",@nfs_tm);
       printa("nfs%d_mx ,%s,%@d\n",@nfs_mx);
       normalize(@nfs_ct,TIMER);
       printa("nfs%d_ct ,%s,%@d\n",@nfs_ct);
       normalize(@nfs_sz,TIMER);
       printa("nfs%d_sz ,%s,%@d\n",@nfs_sz);

       trunc(@nfs_fiw,5);
       normalize(@nfs_fiw,TIMER);
       printa("nfs_fiw ,%s,%s=%s=%d,%@d\n",@nfs_fiw);
       trunc(@nfs_fiw);
       trunc(@nfs_fir,5);
       normalize(@nfs_fir,TIMER);
       printa("nfs_fir ,%s,%s=%s=%d,%@d\n",@nfs_fir);
       trunc(@nfs_fir);

       normalize(@io_tm,TIMER);
       printa("io_tm  ,%s,%@d\n",@io_tm);
       printa("io_mx  ,%s,%@d\n",@io_mx);
       normalize(@io_ct,TIMER);
       printa("io_ct  ,%s,%@d\n",@io_ct);
       normalize(@io_sz,TIMER);
       printa("io_sz  ,%s,%@d\n",@io_sz);

       normalize(@zfs_tm,TIMER);
       printa("zfs%d_tm ,%s,  %@d\n",@zfs_tm);
       printa("zfs%d_mx ,%s,  %@d\n",@zfs_mx);
       normalize(@zfs_ct,TIMER);
       printa("zfs%d_ct ,%s,  %@d\n",@zfs_ct);
       normalize(@zfs_sz,TIMER);
       printa("zfs%d_sz ,%s,  %@d\n",@zfs_sz);

       /*
       # if arrays are not "trunc"-ed then normalize
       # only works the first time ?!
       # change clear(@nfs_sz) to trunc(@nfs_sz)
       printf("normalize nfs_sz by %d\n", TIMER);
       */
       normalize(@nfs_sz,TIMER);
       normalize(@zfs_sz,TIMER);
       normalize(@io_sz,TIMER);

       printa("nfs%d_szps ,%s,%@d\n",@nfs_sz);
       printa("io_szps  ,%s,%@d\n",@io_sz);
       printa("zfs%d_szps ,%s,  %@d\n",@zfs_sz);

       /*
       # file bytes written should be normalized
       */
       normalize(@nfs_avtmsz,TIMER);
       normalize(@nfs_cttmsz,TIMER);
       printa("%s,%s,%@d,%d\n",@nfs_avtmsz);
       printa("%s,%s,%@d,%d\n",@nfs_cttmsz);
       trunc(@nfs_avtmsz);
       trunc(@nfs_cttmsz);

       /*
       # tcp and ip bytes written should be normalized
       */
       normalize(@ip,TIMER);
       normalize(@tcp,TIMER);
       printa("ip,%s,%@d\n",@ip);
       printa("tcp,%s,%@d\n",@tcp);
       trunc(@ip);
       trunc(@tcp);

       trunc(@nfs_tm);
       trunc(@nfs_ct);
       trunc(@nfs_sz);
       trunc(@nfs_hist); 
       trunc(@nfs_tmsz);

       trunc(@io_tm);
       trunc(@io_ct);
       trunc(@io_sz);
       trunc(@io_hist);

       trunc(@zfs_tm);
       trunc(@zfs_ct);
       trunc(@zfs_sz);
       trunc(@zfs_hist);

       trunc(@io_mx);
       trunc(@nfs_mx);
       trunc(@zfs_mx);
}

profile:::tick-1sec
/ COLLECT_NFSOPS == 1 && ticks == 0 /
{
       printf("hist_begin,hist_nfsops\n");
       printa(@nfs_ops_hist);
       printf("hist_end,hist_nfsops\n");
       trunc(@nfs_ops_hist);
}

profile:::tick-1sec
/ COLLECT_TCP == 1 && ticks == 0 /
{
       normalize(@tcp_ct,TIMER);
       normalize(@tcp_sz,TIMER);

       printa("tcp_ct ,%s,%@d\n",@tcp_ct);
       printa("tcp_sz ,%s,%@d\n",@tcp_sz);

       clear(@tcp_ct);
       clear(@tcp_sz);
}

profile:::tick-1sec
/ ticks == 0 /
{
       ticks= TIMER;
       printf("!\n");
}

/* use if you want to print something every TITLE lines */

profile:::tick-1sec / title <= 0 / { title=TITLE; }
EOF
# 
#
#   START of PERL 
#
#
fi| perl -e '

  $CWIDTH=$ENV{'CWIDTH'}||6;
  $PAD=$ENV{'PAD'}||"";
  foreach $argnum (0 .. $#ARGV) {
     ${$ARGV[$argnum]}=1;
     print "$ARGV[$argnum]=${$ARGV[$argnum]}\n";
  }

  $DEBUG=0;

  if  ( 1 == $DEBUG ) { $debug=1; }

  # set up maximum and minimum histogram buckets
  # buckets start at 1us 
  # by setting the bucketmin to 5, the first bucket will contain 2^5, ie 32us 
  # max bucket sets the time of the maximum bucket, everyting in this bucket will be that time or larger

  $bucketmin=6;
  $bucketmax=19;

  @buckett[0]="1u ";
  @buckett[1]="2u ";
  @buckett[2]="4u ";
  @buckett[3]="8u ";
  @buckett[4]="l6u ";
  @buckett[5]="32u ";
  @buckett[6]="64u ";
  @buckett[7]=".1m ";   # 128
  @buckett[8]=".2m ";   # 256
  @buckett[9]=".5m ";   # 512
  @buckett[10]="1m ";   # 1024
  @buckett[11]="2m ";   # 2048
  @buckett[12]="4m ";   # 4096
  @buckett[13]="8m ";   # 8192
  @buckett[14]="16m ";  # 16384
  @buckett[15]="33m ";  # 32768
  @buckett[16]="65m ";  # 65536
  @buckett[17]=".1s";   # 131072
  @buckett[18]=".3s";   # 262144
  @buckett[19]=".5s";   # 524288
  @buckett[20]="1s";    # 1048576
  @buckett[21]="2s";    # 2097152
  @buckett[22]="4s";    # 4194304
  @buckett[23]="8s";    # 8388608
  @buckett[24]="17s";   # 16777216
  @buckett[25]="34s";   # 33554432
  @buckett[26]="67s";   # 67108864


  sub usage {

      printf("usage ioh.pl [hist|nfsops|histsz|histszw|topfile] \n");

  }

  sub print_hist {
         
         $sum_min=0;
         $sum_max=0;
   
         printf("hist_type %20s hist_sub_type %s\n",$hist_type,$hist_sub_type) if defined($debug);

         # highest bucket seen so far for this operation type
         $cur_max_bucket=${$hist_type}{$hist_sub_type}{"maxbucket"};

         # sum up all the buckets below the minimum bucket
         for ($bucket = 0; $bucket <= $bucketmin; $bucket++) {
             $sum_min+= ${$hist_type}{$hist_sub_type}{$bucket} ;
             delete ${$hist_type}{$hist_sub_type}{$bucket};
         }

         # sum up all the buckets above the maximum bucket
         for ($bucket = $bucketmax; $bucket <= $cur_max_bucket; $bucket++) {
             $sum_max+= ${$hist_type}{$hist_sub_type}{$bucket} ;
             delete ${$hist_type}{$hist_sub_type}{$bucket};
         }

         # if maxbucket eq min bucket add the max and min
         if ( $bucketmin < $bucketmax ) { printf ("%*d", $CWIDTH , $sum_min  ); }
         else                           { printf ("%*d", $CWIDTH , $sum_min + $sum_max  ); }
         # iterate through all the buckets between max and min bucket
         for ($bucket = $bucketmin+1; ( $bucket <= $cur_max_bucket && $bucket < $bucketmax ) ; $bucket++) {
             printf ("%*d%s", $CWIDTH , ${$hist_type}{$hist_sub_type}{$bucket},$PAD  );
             $total+=${$hist_type}{$hist_sub_type}{$bucket} ;
             delete ${$hist_type}{$hist_sub_type}{$bucket};
         }
         # print out max bucket if its below the maximum seen so far
         if ( $bucketmax <= $cur_max_bucket &&  $bucketmin  < $bucketmax ) {
            printf ("%*d%s", $CWIDTH ,  $sum_max, $PAD  );
         }
         printf("\n");
    }


  open(MYOUTFILE, ">ioh.out");
  $| = 1;
  while (my $line = <STDIN>) {
       $line=~ s/\s+//g;
       print MYOUTFILE "$line\n";
       next if ($line =~ /^$/);
       printf("=========:%s\n",$line) if defined($debug);
       # line starting with ! mean end of a collection cycle
       if ( $line eq "!"  ) {
          system("clear");
          # convert nanoseconds since 1970 to seconds 
          #printf("date: %d \n",($cur_date/(1000**3)));
          $mydate=$cur_date/(1000**3);
          printf("date: %d , ",$mydate);
         ($sec, $min, $hour, $day,$month,$year) = (localtime($mydate))[0,1,2,3,4,5];
          printf("%d/%d/%d %2d:%2d:%2d\n", $day,$month,$year + 1900 , $hour,$min,$sec );

          #printf("----- TCP ------\n");
          printf("TCP ");
          printf("out: %6.3f MB/s, ", $tcp{"tcpOutDataBytes"}/(1024*1024) );
          printf("in: %6.3f MB/s, ", ($tcp{"tcpInDataInorderBytes"} + $tcp{"tcpInDataUnorderBytes"} ) /(1024*1024) );
          printf("retrans: %6.3f MB/s ", $tcp{"tcpRetransBytes"}/(1024*1024) );
          printf(" ip discards: %6.3f", $ip{"ipIfStatsInDiscards"} );
          printf(" \n");
          delete $tcp{"tcpOutDataBytes"};
          delete $tcp{"tcpRetransBytes"};
          delete $tcp{"tcpInDataInorderBytes"};
          delete $tcp{"tcpInDataUnorderBytes"};
          delete $ip{"ipIfStatsInDiscards"} ;

          printf("----------------\n");
            
      $IOPS=$io_ct{"R"} + $io_ct{"W"};
          # first print out averages (later print out histograms)
          printf("           |%11s|%10s|%10s|%10s\n", 
                            "MB/s",
                            "avg_ms",
                            "avg_sz_kb",
                            "count"
                            );
          printf("-----------|%11.11s|%10.10s|%10.10s|%10s\n", 
                 "--------------------",
                 "--------------------",
                 "--------------------",
                 "--------------------");
          foreach $r_w ("R","W") {
           # zfs1 is zfs sync writes (also set for reads but not used)
           # zfs0 is no-sync zfs writes
           foreach $io_type ("io","zfs1","zfs0","nfs0","nfs1","nfs2","tcp") {
               # ct = count, sz = sum of bytes over period, tm = sum of time for all ops
               if ( $r_w eq "R" && $io_type eq "nfs1" ) { next; }
               if ( $r_w eq "R" && $io_type eq "nfs2" ) { next; }
               if ( $r_w eq "R" && $io_type eq "nfs0" ) {
                  @r_w_c_types =  ("C","R");
               } else {
                  @r_w_c_types =   ( $r_w ) ;
               }
               foreach $r_w_c ( @r_w_c_types ) {
                 foreach $var_type ("ct","sz","tm","szps") {
                    $cur=${$io_type . "_" .  $var_type         }{$r_w_c}||0;
                    ${$var_type}=$cur;
                 }
                 $mx=${$io_type . "_mx"}{$r_w_c}||0 ;
                 $avg_sz_kb=0;
                 $ms_avg=0;
                 $ms_8kb=0;
                 $mx_sz=0;
                 $mx_ms=0;
                 if ( $ct > 0 ) {
                     $ms_avg=(($tm/1000)/$ct);
                     $avg_sz_kb=($sz/$ct)/1024;
                 }
                 if ( $sz > 0 ) {
                     $ms_8kb=(($tm/1000)/($sz/(8*1024)));
                 }

                 # mx_ms is overloaded with the max time and the size for that max time
                 # time is in the upper half and size in the lower
                 $mx_ms=$mx/1000000;
                 $mx_ms=(int($mx/  (1000*1000*1000) )/1000);
                 $mx_sz=(   ($mx % (1000*1000*1000) )/1024);
                   #clear out the make value
                 ${$io_type . "_mx"}{$r_w_c}=0;

                 # sz is already normalized in the dtrace script to per second
                 $sz_MB=$szps/(1024*1024);
                 $io_name=$io_type;

               #  NFS flags
               #  stable_how[0] = "Unstable";
               #  stable_how[1] = "Data_Sync";
               #  stable_how[2] = "File_Sync";
  
                 if ( $io_name eq "nfs0"  ) { $io_name="nfs" } 
                 if ( $r_w_c eq "C"  ) { $io_name="nfs_c" } 
                 if ( $io_name eq "nfs1"  ) { $io_name="nfssyncD" } 
                 if ( $io_name eq "nfs2"  ) { $io_name="nfssyncF" } 
                 if ( $io_name eq "zfs1" && $r_w_c eq "R"  ) { next } 
                 if ( $io_name eq "zfs1"  ) { $io_name="zfssync" } 
                 if ( $io_name eq "zfs0"  ) { $io_name="zfs" } 
  
              # could  add option to print out ms_8k, mx_ms and mx_sz
              # taking out for now to reduce noise of output
                 printf("%1s |%8s:",$r_w_c,$io_name);
                 #printf(" %10.3f",$ms_8kb);
                 printf(" %10.3f",$sz_MB);
                 printf(" %10.2f",$ms_avg);
                 printf(" %10.3f",$avg_sz_kb);
                 #printf(" %10.2f",$mx_ms);
                 #printf(" %10.2f",$mx_sz);
                 printf(" %10d",$ct);
                 print "\n";
                 foreach $var_type ("ct","sz","tm","szps") {
                    ${$io_type . "_" .  $var_type         }{$r_w_c}=0;
                 }
                 $mx=${$io_type . "_mx"}{$r_w_c}||0 ;
              }
            }
              if ( $r_w eq "R" ) { printf("-\n"); }
          }

      if (  $hist==1 || $all == 1 || $histsz == 1 || $histszw ) {
          #  print out histograms
          printf ("%8s %3s ","area","r_w" );
          for ($bucket = $bucketmin; $bucket < $bucketmax; $bucket++) {
                   printf ("%*s", $CWIDTH ,$buckett[$bucket] );
          }
          # highest bucket starts at last bucket up
          printf ("%*s+", $CWIDTH , $buckett[$bucketmax-1] );
          printf("\n");
      }

      if (  $hist==1 || $all == 1 ) {
          printf("---- histograms ------- (total counts over sample period) \n");
          # order the output by reads, then writes, then nfs operations
          foreach $hist_sub_typex ("R","W") {
             foreach $hist_type ("hist_io","hist_zfs","hist_nfs")  {
                 # get "area" out for print "area" to outpout
                 ($histsection, $area)=split("_",$hist_type);
                 # if zfs W had two types WSYNC=sync, W=nonsync
                 $hist_sub_type=$hist_sub_typex;
                     printf("%s %9s ",$hist_sub_type,$area) ; 
                 print_hist;
                 if ( $hist_type eq "hist_zfs" && $hist_sub_typex eq "W" ) { 
                      printf("%s %9s ","W","zfssync") ; 
                      $hist_sub_type="WSYNC";
                      print_hist;
                 } 
              }
              if ( $hist_sub_typex eq "R" ) { printf("-\n"); }
          }
      }
             
      if ( $nfsops==1 ) {
          printf("--- nfs ops ---\n");
          $hist_type="hist_nfsops" ;
          foreach $hist_sub_type ( keys %hist_nfsops_ops) { # ie access, getattr , etc
                printf("%-12s ", $hist_sub_type );
                print_hist;
          }

      }

      foreach $type ("R","W") {
        if ( ( ( $histszw==1 || $all == 1 ) && $type eq "W" ) ||
             ( ( $histsz==1 || $all == 1 ) && $type eq "R" )
         ) {
          if ( $type eq "R" ) { 
             printf("--- NFS latency by size (total counts over sample period) ---------\n");
             printf("  avg_ms size_kb \n",$type);
          } else {
             printf("-\n",$type);
          }
          $hist_type= "hist_nfs_tmsz"; 

          foreach $hist_sub_type  ( sort { $a <=> $b }  keys %hist_nfstmsz) {
            $r_w=$hist_sub_type;
            $r_w=~ s/[0-9]*// ;
            $size=$hist_sub_type;
            $size=~ s/$type// ;
            if ( $type eq $r_w ) {
               # if count is >0, show average time
               if ( $nfs_avg_ctsz{$type}{$size}  > 0 ) {
                 # times are in micro seconds, so divided by 1000 to put into milli
                 printf("%s%6.1f %4d",$type,($nfs_avg_tmsz{$type}{$size}/($nfs_avg_ctsz{$type}{$size}*1000)),$size/1024) ; 
               } else {
                  printf("%s%6s %4d",$type,"",$size/1024) ;
               }
               delete $nfs_avg_tmsz{$type}{$size};
               delete $nfs_avg_ctsz{$type}{$size};
               print_hist;
            }
          }
       }
     }

      if ( $topfile==1 || $all == 1 ) {
          printf("---- top files ----\n");
          printf("   MB/s              IP  PORT filename \n");
          for ($i = 1; $i <= $nfs_fir_ct; $i++) {
             printf("%s \n",$nfs_fir[$i]);
          }
          printf("-\n");
          for ($i = 1; $i <= $nfs_fiw_ct; $i++) {
             printf("%s \n",$nfs_fiw[$i]);
          }
          $nfs_fiw_ct=0; 
          $nfs_fir_ct=0; 
    }

          printf("IOPs  %10d\n",$IOPS);

          # zero out all previous values
          # the histograms get deleted in the loops above
          foreach $r_w ("R","W") {
            foreach $io_type ("io","zfs1","zfs0","nfs","tcp") {
              foreach $var_type ("ct","sz","tm","szps") {
                 ${$io_type . "_" .  $var_type }{$r_w}=0;
              }
            }
          }
          foreach $r_w ("C") {
            foreach $io_type ("nfs") {
              foreach $var_type ("ct","sz","tm","szps") {
                 ${$io_type . "_" .  $var_type }{$r_w}=0;
              }
            }
          }
          printf("----------------------------------------------------------------------------\n");
       } else {
          # parsing input lines
          # example input lines
          #    nfs_avg_ctsz,W,1,16384
          #    nfs_avg_tmsz,W,15188,16384
          ($area, $r_w, $value,$bucket)=split(",",$line);
          # hist end 
          if ( $area eq "hist_end" ) {
             $histsection=0;
             $hist_title=0;
          } 
          if ( $area eq "date" ) {
             $cur_date=$r_w;
          }
          # hist sub type
          elsif ( $area eq "hist_name" ) {
             $hist_sub_type=$r_w;
             if ( $hist_sub_type eq  "W0" ) { $hist_sub_type = "W"; }
             if ( $hist_sub_type eq  "W1" ) { $hist_sub_type = "WSYNC"; }
             if ( $hist_sub_type eq  "R0" ) { $hist_sub_type = "R"; }
             printf("  hist_type:%s\n", $hist_type) if defined($debug) ;
             if ( $hist_type eq "hist_nfsops" )  {
                ($op, $operation, $status)=split("-",$r_w);
                $hist_sub_type=$operation;
                $hist_nfsops_ops{$hist_sub_type}=1;
             }
             if ( $hist_type eq "hist_nfs_tmsz" )  {
                $hist_nfstmsz{$hist_sub_type}=1;
             }
             printf("  hist_sub_type:%s\n", $hist_sub_type)  if defined($debug) ;
             printf("  hist_sub_type,line:%s\n", $line)  if defined($debug); 
             $hist_title=0;
          } 
          elsif ( $area eq "hist_begin" ) {
             $histsection=1;
             $hist_title=1;
             $hist_type=$r_w;
             printf("hist_type:%s\n", $hist_type)  if defined($debug) ;
          }
          # hist data 
          elsif ( $histsection == 1 && $hist_title == 0) {
             printf("line before sub:%s\n", $line)  if defined($debug) ;
             $line=~ s/\|@*/,/;
             printf("line after sub :%s\n", $line)  if defined($debug) ;
             ($bucket,$count)=split(",",$line);
             printf("bucket:%d:,count:%d:\n", $bucket, $count)  if defined($debug) ;
             if ( $bucket > 0 ) {
                $bucket=log($bucket)/log(2)+1;
                printf("log bucket:%d:\n", $bucket)  if defined($debug) ;
                ${$hist_type}{$hist_sub_type}{$bucket}=$count;
                if ( ${$hist_type}{$hist_sub_type}{"maxbucket"} < $bucket && $count > 0 ) {
                   printf("max bucket %s = %d\n",$hist_type, $bucket) if defined($debug);
                   ${$hist_type}{$hist_sub_type}{"maxbucket"}=$bucket;
                }
                printf("   hist_type:%s:,hist_sub_type:%s:,bucket:%d:,count:%d:\n", $hist_type,$hist_sub_type,$bucket,$count)  if defined($debug); ;
             }
          # hist begin type
          } elsif ( $area eq "nfs_fir" ) {
             $bytes=$bucket/(1024*1024);
             ($file, $ip, $port)=split("=",$value);
             if ( $bytes > 0 ) {
               $nfs_fir_ct++;
               $nfs_fir[$nfs_fir_ct]=sprintf("%s %5.2f %15s %5s %s",$r_w,$bytes,$ip,$port,$file); 
             }
          } elsif ( $area eq "nfs_fiw" ) {
             $bytes=$bucket/(1024*1024);
             ($file, $ip, $port)=split("=",$value);
             if ( $bytes > 0 ) {
               $nfs_fiw_ct++;
               $nfs_fiw[$nfs_fiw_ct]=sprintf("%s %5.2f %15s %5s %s",$r_w,$bytes,$ip,$port,$file); 
             }
          #nfs_avg_tmsz,W,15188,16384
          #nfs_avg_ctsz,W,1,16384
          #($area, $r_w, $value,$bucket)=split(",",$line);
          #nfs_avg_tmsz,R,118211,1048576
          #nfs_avg_ctsz,R,32,1048576
          } elsif ( $area eq "nfs_avg_tmsz" || $area eq "nfs_avg_ctsz" ) {
             ${$area}{$r_w}{$bucket}=$value;
             # printf("%s{%s}{%s}=%s\n",$area, $r_w,$bucket, $value);
          } else {   
             ${$area}{$r_w}=$value;
          }
       }
}
' $DISPLAY | sed -e 's/ 0 / . /g'  \
           -e 's/ 0.00 /      /g' \
           -e 's/ 0.000 /       /g' \
           -e 's/ 0$/ ./g' \
           -e '/tcp: *\.$/d'  


