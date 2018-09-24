// Copyright (c) 2009,2018 Simon Fell
//
// Permission is hereby granted, free of charge, to any person obtaining a 
// copy of this software and associated documentation files (the "Software"), 
// to deal in the Software without restriction, including without limitation
// the rights to use, copy, modify, merge, publish, distribute, sublicense, 
// and/or sell copies of the Software, and to permit persons to whom the 
// Software is furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included 
// in all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS 
// OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, 
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE 
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER 
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, 
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN 
// THE SOFTWARE.
//

#import "BulkDelete.h"
#import "ProgressController.h"
#import "EditableQueryResultWrapper.h"
#import "zkSforce.h"
#import "QueryResultTable.h"

@interface BulkDelete ()
-(void)doDeleteFrom:(NSInteger)start length:(NSInteger)length;

@property (strong) QueryResultTable *table;
@end

@interface DeleteOperation : NSOperation {
}
@property (strong) BulkDelete *bulkDelete;
@property (assign) NSInteger start;
@property (assign) NSInteger len;

-(instancetype)initWithDelete:(BulkDelete *)bd startAt:(NSInteger)start length:(NSInteger)l;

@end

@implementation DeleteOperation 

@synthesize bulkDelete, start, len;

-(instancetype)initWithDelete:(BulkDelete *)bd startAt:(NSInteger)startAt length:(NSInteger)length {
    self = [super init];
    self.bulkDelete = bd;
    self.start = startAt;
    self.len = length;
    return self;
}

-(void)main {
    @autoreleasepool {
        [bulkDelete doDeleteFrom:start length:len];
    }
}

@end

@implementation BulkDelete

@synthesize table;

-(instancetype)initWithClient:(ZKSforceClient *)c {
    self = [super init];
    progress = [[ProgressController alloc] init];
    queue = [[NSOperationQueue alloc] init];
    queue.maxConcurrentOperationCount = 1;
    client = [c copy];
    return self;
}

-(void)extractRows:(EditableQueryResultWrapper *)dataSource {
    NSSet *idxSet = [dataSource indexesOfCheckedRows];
    ZKQueryResult *data = [dataSource queryResult];
    NSMutableArray *ia  = [NSMutableArray arrayWithCapacity:idxSet.count];
    NSMutableArray *ids = [NSMutableArray arrayWithCapacity:idxSet.count];
    for (NSNumber *idx in idxSet) {
        [ia addObject:idx];
        ZKSObject *row = [data records][idx.intValue];
        [ids addObject:[row id]];
    }
    indexes = ia;
    sfdcIds = ids;
    results = [NSMutableArray arrayWithCapacity:idxSet.count];
}

-(void)performBulkDelete:(QueryResultTable *)queryResultTable window:(NSWindow *)modalWindow {
    self.table = queryResultTable;
    EditableQueryResultWrapper *dataSource = queryResultTable.wrapper;
    progress.progressLabel = [NSString stringWithFormat:@"Deleting %lu rows", (unsigned long)[dataSource numCheckedRows]];
    progress.progressValue = 1.0;
    [NSApp beginSheet:progress.progressWindow modalForWindow:modalWindow modalDelegate:self didEndSelector:nil contextInfo:nil];
    [self extractRows:dataSource];

    // enqueue delete operations
    int start = 0;
    int chunk = 50;
    do {
        NSInteger len = indexes.count - start;
        if (len > chunk) len = chunk;
        DeleteOperation *op = [[DeleteOperation alloc] initWithDelete:self startAt:start length:len];
        [queue addOperation:op];
        start += len;
    } while (start < indexes.count);
}

-(void)deletesFinished {
    int cnt = 0;
    // save errors to table
    [table.wrapper clearErrors];
    NSMutableArray *deleted = [NSMutableArray array];
    for (ZKSaveResult *r in results) {
        NSNumber *idx = indexes[cnt];
        if (r.success) {
            [deleted addObject:idx];
            [table.wrapper setChecked:NO onRowWithIndex:idx];
        } else {
            [table.wrapper addError:r.description forRowIndex:idx];
        }
        ++cnt;
    }
    [table showHideErrorColumn];
    // remove the successfully deleted rows from the queryResults.
    NSArray *sorted = [deleted sortedArrayUsingSelector:@selector(compare:)];
    id ctx = [table.wrapper createMutatingRowsContext];
    NSNumber *idx;
    NSEnumerator *e = [sorted reverseObjectEnumerator];
    while (idx = [e nextObject])
        [table.wrapper remmoveRowAtIndex:idx.intValue context:ctx];
    [table.wrapper updateRowsFromContext:ctx];
    [table replaceQueryResult:[table.wrapper queryResult]];
    
    // remove the progress sheet, and tidy up
    [NSApp endSheet:progress.progressWindow];
    [progress.progressWindow orderOut:self];
     // we're outa here
}

-(void)aboutToDeleteFromIndex:(NSNumber *)idx {
    NSString *l = [NSString stringWithFormat:@"Deleting %d of %ld rows", idx.intValue, (unsigned long)indexes.count];
    progress.progressLabel = l;
}

-(void)doDeleteFrom:(NSInteger)start length:(NSInteger)length {
    [self performSelectorOnMainThread:@selector(aboutToDeleteFromIndex:) withObject:@(start+length) waitUntilDone:NO];
    NSArray *ids = [sfdcIds subarrayWithRange:NSMakeRange(start, length)];
    NSArray *res = [client delete:ids];
    [results addObjectsFromArray:res];
    if (results.count == sfdcIds.count) {
        // all done, lets wrap up
        [self performSelectorOnMainThread:@selector(deletesFinished) withObject:nil waitUntilDone:NO];
    }
}

@end
