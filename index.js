const { DynamoDB } = require('@aws-sdk');
const fs = require('fs/promises');

const { mapHandler } = require('./handlers');

async function uploadMetadataToDynamo(event) {
    try {
        const tableName = process.env.DYNAMO_METADATA_TABLE_NAME;
        if (tableName) {
            const {
                requestContext: {
                    http: {
                        method,
                        path,
                        sourceIp,
                    },
                },
            } = event;

            const requestSourceIp = Buffer.from(sourceIp).toString('base64');

            const dynamo = new DynamoDB();
            let { Items: [existingRow] } = await dynamo.query({
                ExpressionAttributeValues: {
                    ':requestSourceIp': {
                        S: requestSourceIp,
                    },
                    ':requestPath': {
                        S: path,
                    },
                },
                KeyConditionExpress: 'sourceIp = :requestSourceIp AND path = :requestPath',
                ProjectionExpression: 'count,method,path,sourceIp',
                TableName: tableName,
            }).promise();

            if (!existingRow) {
                existingRow = {
                    count: {
                        N: 0,
                    },
                    method: {
                        S: method,
                    },
                    path: {
                        S: path,
                    },
                    sourceIp: {
                        S: requestSourceIp,
                    },
                };
            }

            existingRow.count++;

            return await dynamo.putItem({
                Item: existingRow,
                TableName: tableName,
            });
        }

        console.warn(`Env variable 'DYNAMO_METADATA_TABLE_NAME' not configured, not uploading metadata to DynamoDB`);
    } catch (e) {
        console.error(e);
    }
}

exports.handler = async event => {
    try {
        uploadMetadataToDynamo(event);

        const { requestContext: { http: { sourceIp } } } = event;

        console.log(`Request from IP address '${sourceIp}'`);

        const handler = mapHandler(event);

        if (handler) {
            console.log(`Using handler '${JSON.stringify(handler)}' for path '${event.rawPath}'`);
            
            return handler.action(event);
        }
        
        return {
            statusCode: 404,
            headers: {
                'Content-Type': 'text/html',  
            },
            body: await fs.readFile('./404.html', 'utf8'),
        };
    } catch (e) {
        console.error('Encountered an unhandled exception:', e);

        return {
            statusCode: 500,
            headers: {
                'Content-Type': 'text/plain',
            },
            body: e.message,
        };
    }
};
