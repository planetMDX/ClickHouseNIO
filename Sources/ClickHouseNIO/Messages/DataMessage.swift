//
//  DataMessage.swift
//  ClickHouseNIO
//
//  Created by Patrick Zippenfenig on 2019-11-26.
//

import Foundation
import NIO

struct DataMessage {
    let table_name: String?
    
    /**
     After running GROUP BY ... WITH TOTALS with the max_rows_to_group_by and group_by_overflow_mode = 'any' settings, a row is inserted in the separate block with aggregated values that have not passed max_rows_to_group_by. If it is such a block, then is_overflows is set to true for it.
     */
    let is_overflows: UInt8
    
    /**
     When using the two-level aggregation method, data with different key groups are scattered across different buckets. In this case, the bucket number is indicated here. It is used to optimize the merge for distributed aggregation. Otherwise -1.
     */
    let bucket_num: Int32
    
    let columns: [(column: String, values: [ClickHouseDataType], type: ClickHouseTypeName)]
    
    var columnCount: Int {
        return columns.count
    }
    
    /// Get the number of rows
    var rowCount: Int {
        return columns.first?.values.count ?? 0
    }
    
    public init(is_overflows : UInt8 = 0, bucket_num : Int32 = -1, columns: [(column: String, values: [ClickHouseDataType], type: ClickHouseTypeName)] = []) {
        self.is_overflows = is_overflows
        self.bucket_num = bucket_num
        self.columns = columns
        self.table_name = ""
    }
    
    public init?(from buffer: inout ByteBuffer, revision: UInt64) {
        if revision >= ClickHouseMessageDecoder.DBMS_MIN_REVISION_WITH_TEMPORARY_TABLES {
            guard let table_name = buffer.readClickHouseString() else {
                return nil
            }
            self.table_name = table_name
        } else {
            self.table_name = nil
        }
        
        // compression would go here and has to decompress the bytebuffer stream
        
        if revision >= ClickHouseMessageDecoder.DBMS_MIN_REVISION_WITH_BLOCK_INFO {
            guard let num1 = buffer.readVarInt64(),
                let isOverflows: UInt8 = buffer.readInteger(),
                let num2 = buffer.readVarInt64(),
                let bucketNum: Int32 = buffer.readInteger(),
                let num3 = buffer.readVarInt64() else {
                    return nil
            }
            self.is_overflows = isOverflows
            self.bucket_num = bucketNum
            //print("num1", num1, "isOverflows", isOverflows, "num2", num2, "bucketNum", bucketNum, "num3", num3)
            assert(num1 == 1)
            assert(num2 == 2)
            assert(num3 == 0)
        } else {
            self.is_overflows = 0
            self.bucket_num = -1
        }
        
        guard let numColumns = buffer.readVarInt64(),
            let numRows = buffer.readVarInt64() else {
                return nil
        }
        //print("numColumns \(numColumns) numRows \(numRows)")
        
        var columns = [(column: String, values: [ClickHouseDataType], type: ClickHouseTypeName)]()
        columns.reserveCapacity(Int(numColumns))
        for _ in 0..<numColumns {
            guard let name = buffer.readClickHouseString(),
                let type = buffer.readClickHouseString() else {
                    return nil // need more data
            }
            guard let typeEnum = ClickHouseTypeName(type) else {
                fatalError("Unknown type \(type)")
            }
            guard let array = buffer.toClickHouseArray(type: typeEnum, numRows: Int(numRows)) else {
                return nil // need more data
            }
            //print("Column: \(name), Type: \(type)")
            columns.append((name, array, typeEnum))
        }
        self.columns = columns
    }
    
    func addToBuffer(buffer : inout ByteBuffer, revision : UInt64) {
        let rows = self.columns.first?.values.count ?? 0
        for (_, column, _) in self.columns {
            assert(rows == column.count, "addToBuffer wrong column count")
        }
        buffer.writeVarInt64(ClientCodes.Data.rawValue)
        
        if revision >= ClickHouseMessageDecoder.DBMS_MIN_REVISION_WITH_TEMPORARY_TABLES {
            buffer.writeClickHouseString(self.table_name ?? "")
        }
        
        if revision >= ClickHouseMessageDecoder.DBMS_MIN_REVISION_WITH_BLOCK_INFO {
            buffer.writeVarInt64(UInt64(1))
            buffer.writeInteger(self.is_overflows)
            buffer.writeVarInt64(UInt64(2))
            buffer.writeInteger(self.bucket_num)
            buffer.writeVarInt64(UInt64(0))
        }
        
        buffer.writeVarInt64(UInt64(self.columns.count))
        buffer.writeVarInt64(UInt64(rows))
        
        // TODO the required buffer space might be very high... consider to stream one column after another
        for (column, values, type) in self.columns {
            buffer.writeClickHouseString(column)
            buffer.writeClickHouseString(type.string)
            buffer.loadFromClickHouseArray(array: values, fixedLength: type.fixedLength)
        }
    }
}
