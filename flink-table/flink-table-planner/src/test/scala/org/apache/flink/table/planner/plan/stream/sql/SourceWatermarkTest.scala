/*
 * Licensed to the Apache Software Foundation (ASF) under one
 * or more contributor license agreements.  See the NOTICE file
 * distributed with this work for additional information
 * regarding copyright ownership.  The ASF licenses this file
 * to you under the Apache License, Version 2.0 (the
 * "License"); you may not use this file except in compliance
 * with the License.  You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
package org.apache.flink.table.planner.plan.stream.sql

import org.apache.flink.table.planner.runtime.utils.JavaUserDefinedScalarFunctions.JavaFunc5
import org.apache.flink.table.planner.utils.TableTestBase

import org.junit.jupiter.api.{BeforeEach, Test}
import org.junit.jupiter.params.ParameterizedTest
import org.junit.jupiter.params.provider.ValueSource

/** Tests for watermark push down. */
class SourceWatermarkTest extends TableTestBase {

  private val util = streamTestUtil()

  @BeforeEach
  def setup(): Unit = {
    util.tableEnv.executeSql(s"""
                                | CREATE TABLE VirtualTable (
                                |   a INT,
                                |   b BIGINT,
                                |   c TIMESTAMP(3),
                                |   d AS c + INTERVAL '5' SECOND,
                                |   WATERMARK FOR d AS d - INTERVAL '5' SECOND
                                | ) WITH (
                                |   'connector' = 'values',
                                |   'enable-watermark-push-down' = 'true',
                                |   'bounded' = 'false',
                                |   'disable-lookup' = 'true'
                                | )
         """.stripMargin)

    util.tableEnv.executeSql(s"""
                                | CREATE TABLE NestedTable (
                                |   a INT,
                                |   b BIGINT,
                                |   c ROW<name STRING, d ROW<e STRING, f TIMESTAMP(3)>>,
                                |   g AS c.d.f,
                                |   WATERMARK FOR g AS g - INTERVAL '5' SECOND
                                | ) WITH (
                                |   'connector' = 'values',
                                |   'enable-watermark-push-down' = 'true',
                                |   'nested-projection-supported' = 'true',
                                |   'bounded' = 'false',
                                |   'disable-lookup' = 'true'
                                | )
         """.stripMargin)

    JavaFunc5.closeCalled = false
    JavaFunc5.openCalled = false
    util.addTemporarySystemFunction("func", new JavaFunc5)
    util.tableEnv.executeSql(s"""
                                | CREATE Table UdfTable (
                                |   a INT,
                                |   b BIGINT,
                                |   c timestamp(3),
                                |   d as func(c, a),
                                |   WATERMARK FOR c as func(func(d, a), a)
                                | ) with (
                                |   'connector' = 'values',
                                |   'bounded' = 'false',
                                |   'enable-watermark-push-down' = 'true',
                                |   'disable-lookup' = 'true'
                                | )
         """.stripMargin)

    util.tableEnv.executeSql(
      s"""
         | CREATE TABLE MyTable(
         |   a INT,
         |   b BIGINT,
         |   c TIMESTAMP(3),
         |   originTime BIGINT METADATA,
         |   rowtime AS TO_TIMESTAMP(FROM_UNIXTIME(originTime/1000), 'yyyy-MM-dd HH:mm:ss'),
         |   WATERMARK FOR rowtime AS rowtime
         | ) WITH (
         |   'connector' = 'values',
         |   'enable-watermark-push-down' = 'true',
         |   'bounded' = 'false',
         |   'disable-lookup' = 'true',
         |   'readable-metadata' = 'originTime:BIGINT'
         | )
         """.stripMargin)

    util.tableEnv.executeSql(s"""
                                | CREATE TABLE MyLtzTable(
                                |   a INT,
                                |   b BIGINT,
                                |   c TIMESTAMP(3),
                                |   originTime BIGINT METADATA,
                                |   rowtime AS TO_TIMESTAMP_LTZ(originTime, 3),
                                |   WATERMARK FOR rowtime AS rowtime
                                | ) WITH (
                                |   'connector' = 'values',
                                |   'enable-watermark-push-down' = 'true',
                                |   'bounded' = 'false',
                                |   'disable-lookup' = 'true',
                                |   'readable-metadata' = 'originTime:BIGINT'
                                | )
         """.stripMargin)

    util.tableEnv.executeSql(s"""
                                | CREATE TABLE timeTestTable(
                                |   a INT,
                                |   b BIGINT,
                                |   rowtime AS TO_TIMESTAMP_LTZ(b, 0),
                                |   WATERMARK FOR rowtime AS rowtime
                                | ) WITH (
                                |   'connector' = 'values',
                                |   'enable-watermark-push-down' = 'true',
                                |   'bounded' = 'false',
                                |   'disable-lookup' = 'true'
                                | )
         """.stripMargin)
  }

  @Test
  def testSimpleWatermarkPushDown(): Unit = {
    util.verifyExecPlan("SELECT a, b, c FROM VirtualTable")
  }

  @Test
  def testWatermarkOnComputedColumnExcludedRowTime2(): Unit = {
    util.verifyExecPlan("SELECT a, b, SECOND(d) FROM VirtualTable")
  }

  @Test
  def testWatermarkOnComputedColumnExcluedRowTime1(): Unit = {
    util.verifyExecPlan("SELECT a, b FROM VirtualTable WHERE b > 10")
  }

  @Test
  def testWatermarkOnNestedRowWithNestedProjection(): Unit = {
    util.verifyExecPlan("select c.e, c.d from NestedTable")
  }

  @Test
  def testWatermarkWithUdf(): Unit = {
    util.verifyExecPlan("SELECT a - b FROM UdfTable")
  }

  @Test
  def testWatermarkWithMetadata(): Unit = {
    util.verifyExecPlan("SELECT a, b FROM MyTable")
  }

  @Test
  def testWatermarkOnTimestampLtzCol(): Unit = {
    util.verifyExecPlan("SELECT a, b FROM MyLtzTable")
  }

  @Test
  def testWatermarkOnCurrentRowTimestampFunction(): Unit = {
    util.verifyExecPlan("SELECT * FROM timeTestTable")
  }

  @Test
  def testProjectTransposeWatermarkAssigner(): Unit = {
    val sourceDDL =
      s"""
         |CREATE TEMPORARY TABLE `t1` (
         |  `a`  VARCHAR,
         |  `b`  VARCHAR,
         |  `c`  VARCHAR,
         |  `d`  INT,
         |  `t`  TIMESTAMP(3),
         |  `ts` AS `t`,
         |  WATERMARK FOR `ts` AS `ts` - INTERVAL '10' SECOND
         |) WITH (
         |  'connector' = 'values',
         |  'enable-watermark-push-down' = 'true',
         |  'bounded' = 'false',
         |  'disable-lookup' = 'true'
         |)
       """.stripMargin
    util.tableEnv.executeSql(sourceDDL)
    util.verifyExecPlan("SELECT a, b, ts FROM t1")
  }

  @ParameterizedTest
  @ValueSource(
    strings = Array[String](
      "`ts` - ( - ( - (INTERVAL '10' SECOND)))",
      "`ts` - ARRAY[INTERVAL '10' SECOND, INTERVAL '1' SECOND][1]",
      "`ts` - CASE WHEN true THEN INTERVAL '10' SECOND ELSE INTERVAL '2' SECOND END"
    ))
  def testProjectTransposeWatermarkAssignerWithSimplifiableWatermarks(
      watermarkExp: String): Unit = {
    val sourceDDL =
      s"""
         |CREATE TEMPORARY TABLE `t1` (
         |  `a`  VARCHAR,
         |  `b`  VARCHAR,
         |  `c`  VARCHAR,
         |  `d`  INT,
         |  `t`  TIMESTAMP(3),
         |  `ts` AS `t`,
         |  WATERMARK FOR `ts` AS $watermarkExp
         |) WITH (
         |  'connector' = 'values',
         |  'enable-watermark-push-down' = 'true',
         |  'bounded' = 'false',
         |  'disable-lookup' = 'true'
         |)
       """.stripMargin
    util.tableEnv.executeSql(sourceDDL)
    util.verifyExecPlan("SELECT a, b, ts FROM t1")
  }
}
