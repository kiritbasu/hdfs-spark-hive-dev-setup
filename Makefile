mkfile_path := $(abspath $(lastword $(MAKEFILE_LIST)))
current_dir := $(dir $(mkfile_path))
hive_home := $(addsuffix tools/apache-hive-2.3.7-bin, $(current_dir))
hadoop_home := $(addsuffix tools/hadoop-2.7.7, $(current_dir))
spark_home := $(addsuffix tools/spark-2.4.4-bin-hadoop2.7, $(current_dir))
j_home := /usr/java/jdk1.8.0_261-amd64

#########################################
# Configuration and start/stop commands #
#########################################
configure_pmem_first_time:
	ndctl create-namespace -m fsdax -r region0
	ndctl create-namespace -m fsdax -r region1
	mkdir /mnt/pmem0	
	mkdir /mnt/pmem1
	mkfs.ext4 -b 4096 -E stride=512 -F /dev/pmem0	
	mkfs.ext4 -b 4096 -E stride=512 -F /dev/pmem1
	
mount_pmem:
	mount -o dax /dev/pmem0 /mnt/pmem0
	mount -o dax /dev/pmem1 /mnt/pmem1

download: download_hadoop download_spark download_hive

download_hadoop:
	mkdir -p ${current_dir}tools
	cd ${current_dir}tools; wget --no-check-certificate https://archive.apache.org/dist/hadoop/common/hadoop-2.7.7/hadoop-2.7.7.tar.gz && tar -xvf hadoop-2.7.7.tar.gz && rm -rf hadoop-2.7.7.tar.gz

download_spark:
	mkdir -p ${current_dir}tools
	cd ${current_dir}tools; wget --no-check-certificate https://archive.apache.org/dist/spark/spark-2.4.4/spark-2.4.4-bin-hadoop2.7.tgz && tar -xvf spark-2.4.4-bin-hadoop2.7.tgz && rm -rf spark-2.4.4-bin-hadoop2.7.tgz

download_spark_oap:
	mkdir -p ${current_dir}tools
	cd ${current_dir}tools; wget --no-check-certificate https://github.com/Intel-bigdata/OAP/releases/download/v0.8.0-spark-2.4.4/oap-product-0.8.0-bin-spark-2.4.4.tar.gz && oap-product-0.8.0-bin-spark-2.4.4.tar.gz && rm -rf oap-product-0.8.0-bin-spark-2.4.4.tar.gz
	
download_vmemcache:
	mkdir -p ${current_dir}tools
	cd ${current_dir}tools; wget --no-check-certificate https://github.com/Intel-bigdata/OAP/releases/download/v0.8.0-spark-2.4.4/libvmemcache-0.8.rpm && rpm -i libvmemcache*.rpm
	
download_hive:
	mkdir -p ${current_dir}tools
	cd ${current_dir}tools; wget --no-check-certificate https://apache.claz.org/hive/hive-2.3.7/apache-hive-2.3.7-bin.tar.gz && tar -xvf apache-hive-2.3.7-bin.tar.gz && rm -rf apache-hive-2.3.7-bin.tar.gz

configure: configure_hadoop configure_spark

configure_hadoop:
	#Set JAVA_HOME explicitly
	sed -i "s#.*export JAVA_HOME.*#export JAVA_HOME=${JAVA_HOME}#g" ${hadoop_home}/etc/hadoop/hadoop-env.sh 
	#Set HADOOP_CONF_DIR explicitly
	sed -i "s#.*export HADOOP_CONF_DIR.*#export HADOOP_CONF_DIR=${hadoop_home}/etc/hadoop#" ${hadoop_home}/etc/hadoop/hadoop-env.sh
	#define fs.default.name in core-site.xml
	sed -i '/<\/configuration>/i <property><name>fs.default.name</name><value>hdfs://localhost:9000</value></property>' ${hadoop_home}/etc/hadoop/core-site.xml
	sed -i '/<\/configuration>/i <property><name>hadoop.tmp.dir</name><value>file://${current_dir}data/hadoop-tmp</value></property>' ${hadoop_home}/etc/hadoop/core-site.xml
	#set dfs.replication and dfs.namenode.name.dir
	mkdir -p ${current_dir}data/hadoop
	sed -i '/<\/configuration>/i <property><name>dfs.replication</name><value>1</value></property>' ${hadoop_home}/etc/hadoop/hdfs-site.xml
	sed -i '/<\/configuration>/i <property><name>dfs.namenode.name.dir</name><value>file://${current_dir}data/hadoop</value></property>' ${hadoop_home}/etc/hadoop/hdfs-site.xml
	${hadoop_home}/bin/hdfs namenode -format
	ssh-keygen -t dsa -P '' -f ~/.ssh/id_dsa
	cat ~/.ssh/id_dsa.pub >> ~/.ssh/authorized_keys
	chmod 0600 ~/.ssh/authorized_keys
	ssh-add

start_hadoop:
	${hadoop_home}/sbin/start-dfs.sh
stop_hadoop:
	${hadoop_home}/sbin/stop-dfs.sh

configure_spark:
	# Change logging level from INFO to WARN
	cp ${spark_home}/conf/log4j.properties.template ${spark_home}/conf/log4j.properties
	sed -i "s#log4j.rootCategory=INFO, console#log4j.rootCategory=WARN, console#g" ${spark_home}/conf/log4j.properties
	# Set up Spark environment variables
	echo 'export SPARK_LOCAL_IP=127.0.0.1' >> ${spark_home}/conf/spark-env.sh
	echo 'export HADOOP_CONF_DIR="${hadoop_home}/etc/hadoop"'>> ${spark_home}/conf/spark-env.sh
	echo 'export SPARK_DIST_CLASSPATH="$(shell ${hadoop_home}/bin/hadoop classpath)"'>> ${spark_home}/conf/spark-env.sh
	echo 'export SPARK_MASTER_IP=127.0.0.1'>> ${spark_home}/conf/spark-env.sh
	mkdir -p ${current_dir}data/spark-rdd
	echo 'export SPARK_LOCAL_DIRS=${current_dir}data/spark-rdd'

configure_spark_oap:
	#setup persistent memory config
	echo '<persistentMemoryPool><numanode id="0"><initialPath>/mnt/pmem0</initialPath></numanode><numanode id="1"><initialPath>/mnt/pmem1</initialPath></numanode></persistentMemoryPool>' >> ${spark_home}/conf/persistent-memory.xml
	#setup OAP
	echo 'spark.sql.extensions                  org.apache.spark.sql.OapExtensions' >> ${spark_home}/conf/spark-defaults.conf
	echo 'spark.files                       /root/oap/jars/oap-cache-0.8.0-with-spark-2.4.4.jar:/root/oap/jars/oap-common-0.8.0-with-spark-2.4.4.jar:/root/oap/jars/oap-spark-0.8.0-with-spark-2.4.4.jar' >> ${spark_home}/conf/spark-defaults.conf
	echo 'spark.executor.extraClassPath     /root/oap/jars/oap-cache-0.8.0-with-spark-2.4.4.jar:/root/oap/jars/oap-common-0.8.0-with-spark-2.4.4.jar:/root/oap/jars/oap-spark-0.8.0-with-spark-2.4.4.jar' >> ${spark_home}/conf/spark-defaults.conf
	echo 'spark.driver.extraClassPath       /root/oap/jars/oap-cache-0.8.0-with-spark-2.4.4.jar:/root/oap/jars/oap-common-0.8.0-with-spark-2.4.4.jar:/root/oap/jars/oap-spark-0.8.0-with-spark-2.4.4.jar' >> ${spark_home}/conf/spark-defaults.conf
	echo 'spark.executor.memoryOverhead                  		   50g' >> ${spark_home}/conf/spark-defaults.conf
	echo 'spark.driver.memory					   50g' >> ${spark_home}/conf/spark-defaults.conf
	echo 'spark.executor.memory					   50g' >> ${spark_home}/conf/spark-defaults.conf
	echo 'spark.executor.instances                                   6' >> ${spark_home}/conf/spark-defaults.conf
	echo 'spark.yarn.numa.enabled                                    true' >> ${spark_home}/conf/spark-defaults.conf
	echo 'spark.executorEnv.MEMKIND_ARENA_NUM_PER_KIND               1' >> ${spark_home}/conf/spark-defaults.conf
	echo 'spark.memory.offHeap.enabled                               false' >> ${spark_home}/conf/spark-defaults.conf
	echo 'spark.speculation                                          false' >> ${spark_home}/conf/spark-defaults.conf
	echo 'spark.sql.oap.fiberCache.persistent.memory.initial.size    256g' >> ${spark_home}/conf/spark-defaults.conf
	echo 'spark.sql.oap.fiberCache.persistent.memory.reserved.size   50g' >> ${spark_home}/conf/spark-defaults.conf
	echo 'spark.sql.oap.cache.guardian.memory.size	           50g' >> ${spark_home}/conf/spark-defaults.conf
	echo 'spark.sql.oap.parquet.data.cache.enable           	   true' >> ${spark_home}/conf/spark-defaults.conf
	echo '# PM on Guava' >> ${spark_home}/conf/spark-defaults.conf
	echo 'spark.sql.oap.fiberCache.memory.manager                    pm' >> ${spark_home}/conf/spark-defaults.conf
	echo 'spark.oap.cache.strategy                                   vmem' >> ${spark_home}/conf/spark-defaults.conf
	echo '#NoEvict' >> ${spark_home}/conf/spark-defaults.conf
	echo '#spark.sql.oap.fiberCache.memory.manager                     hybrid' >> ${spark_home}/conf/spark-defaults.conf
	echo '#spark.oap.cache.strategy                                    noevict' >> ${spark_home}/conf/spark-defaults.conf
	echo '# DRAM Cache' >> ${spark_home}/conf/spark-defaults.conf
	echo '#spark.sql.oap.fiberCache.memory.manager                    offheap' >> ${spark_home}/conf/spark-defaults.conf
	echo '#spark.sql.oap.fiberCache.offheap.memory.size               50g' >> ${spark_home}/conf/spark-defaults.conf

	
start_spark:
	${spark_home}/sbin/start-master.sh
	${spark_home}/sbin/start-slaves.sh spark://sdp:7077
stop_spark:
	${spark_home}/sbin/stop-master.sh
	${spark_home}/sbin/stop-slaves.sh

configure_hive:
	echo "Installing JDBC for Java 8. If you use other Java version see: https://jdbc.postgresql.org/download.html#current"
	wget --no-check-certificate https://jdbc.postgresql.org/download/postgresql-9.4.1209.jar
	mv postgresql-9.4.1209.jar ${hive_home}/lib/
	#enable JDBC connection
	echo '<?xml version="1.0" encoding="UTF-8" standalone="no"?>' >> ${hive_home}/conf/hive-site.xml
	echo '<?xml-stylesheet type="text/xsl" href="configuration.xsl"?>' >> ${hive_home}/conf/hive-site.xml
	echo '<configuration>' >> ${hive_home}/conf/hive-site.xml
	#echo '<property><name>javax.jdo.option.ConnectionURL</name><value>jdbc:derby:;databaseName=${current_dir}metastore_db;create=true</value></property>' >> ${hive_home}/conf/hive-site.xml
	echo '<property><name>javax.jdo.option.ConnectionURL</name><value>jdbc:postgresql://localhost/metastore</value></property>' >> ${hive_home}/conf/hive-site.xml
	echo '<property><name>javax.jdo.option.ConnectionDriverName</name><value>org.postgresql.Driver</value></property>' >> ${hive_home}/conf/hive-site.xml
	echo '<property><name>javax.jdo.option.ConnectionUserName</name><value>hive</value></property>' >> ${hive_home}/conf/hive-site.xml
	echo '<property><name>javax.jdo.option.ConnectionPassword</name><value>hive</value></property>' >> ${hive_home}/conf/hive-site.xml
	echo '<property><name>datanucleus.autoCreateSchema</name><value>false</value></property>' >> ${hive_home}/conf/hive-site.xml
	echo '<property><name>hive.metastore.uris</name><value>thrift://127.0.0.1:9083</value></property>' >> ${hive_home}/conf/hive-site.xml
	echo '<property><name>hive.server2.enable.doAs</name><value>FALSE</value></property>' >> ${hive_home}/conf/hive-site.xml
	echo '</configuration>' >> ${hive_home}/conf/hive-site.xml
	#Copy hive-stie.xml to Spark -- necessary to run Spark apps with configured metastore
	cp ${hive_home}/conf/hive-site.xml ${spark_home}/conf/
	#export environment variables
	echo 'export HADOOP_HOME="${hadoop_home}"' >> ${hive_home}/conf/hive-env.sh
	echo 'export HIVE_HOME="${hive_home}"' >> ${hive_home}/conf/hive-env.sh
	#Create hdfs folders
	${hadoop_home}/bin/hadoop fs -mkdir -p /tmp
	${hadoop_home}/bin/hadoop fs -mkdir -p /user/hive/warehouse
	${hadoop_home}/bin/hadoop fs -chmod g+w /tmp
	${hadoop_home}/bin/hadoop fs -chmod g+w /user/hive/warehouse

start_hive:
	${hive_home}/bin/hive
start_hive_server:
	${hive_home}/bin/hiveserver2 --hiveconf hive.server2.enable.doAs=false
start_hive_beeline_client:
	${hive_home}/bin/beeline -u jdbc:hive2://localhost:10000
start_hive_postgres_metastore:
	echo "Starting postgres docker container"
	docker run -d --name hive-metastore -p 5432:5432 bde2020/hive-metastore-postgresql:2.3.0
	sleep 5;
	echo "Running Hive Metastore service"
	${hive_home}/bin/hive --service metastore


######################
# Interactive shells #
######################

pyspark:
	IPYTHON=1 ${spark_home}/bin/pyspark
spark_shell:
	${spark_home}/bin/spark-shell

#########################################
# Inject bin/ directories into the PATH #
#########################################

activate:
	echo "export PATH=${PATH}:${spark_home}/bin:${hadoop_home}/bin:${hive_home}/bin" >> activate
	chmod a+x activate
	echo "Run the following command in your terminal:"
	echo "source activate"
