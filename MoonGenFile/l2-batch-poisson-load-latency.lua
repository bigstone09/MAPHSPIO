local mg        = require "moongen"
local memory    = require "memory"
local ts        = require "timestamping"
local device    = require "device"
local stats     = require "stats"
local timer     = require "timer"
local histogram = require "histogram"
local log       = require "log"

local PKT_SIZE = 60

function configure(parser)
	parser:description("Generates traffic based on a poisson process with CRC-based rate control.")
	parser:argument("Dev1", "Device to transmit from."):convert(tonumber)
	--parser:argument("Dev2", "Device to receive from."):convert(tonumber)
	parser:option("-r --rate", "Transmit rate in Mpps."):convert(tonumber)
	parser:option("-p --phi", "Max batch arrival size in Zipf's Law."):convert(tonumber)
	parser:option("-v --burstdegree", "burst degree in Zipf's Law."):convert(tonumber)
end

function master(args)
	local Dev1 = device.config({port = args.Dev1, txQueues = 2, rxQueues = 2})
	--local Dev2 = device.config({port = args.Dev2, txQueues = 2, rxQueues = 2})
	rate = 14.88*args.rate
	phi = args.phi
	v = args.burstdegree
	device.waitForLinks()

	mg.startTask("loadSlave", Dev1, Dev1, Dev1:getTxQueue(0), rate, PKT_SIZE, phi, v)
	mg.startTask("timerSlave", Dev1:getTxQueue(1), Dev1:getRxQueue(1), PKT_SIZE)

	
	--mg.startTask("loadSlave", Dev2, Dev2, Dev2:getTxQueue(0), rate, PKT_SIZE, phi, v)
	--mg.startTask("timerSlave", Dev2:getTxQueue(1), Dev2:getRxQueue(1), PKT_SIZE)

	mg.waitForTasks()
end

function getProTable(n,tau)
	 local ProTable = {}
	 local Sum = 0
	 for i=1,n do
	     ProTable[i] = 1.0/(i^tau)
	     Sum = Sum + 1.0/(i^tau)
	 end
	 local avgBatchSize = 0;
	 for i=1,n do
	     ProTable[i] = ProTable[i]/Sum
	     avgBatchSize = avgBatchSize + i*ProTable[i]
	     if( i > 1 )
	     then
		ProTable[i] = ProTable[i] + ProTable[i-1]
	     end
	 end
	 return ProTable,avgBatchSize/1.0
end

function loadSlave(dev, rxDev, queue, rate, size, n, tau)
	local mem = memory.createMemPool(function(buf)
		buf:getEthernetPacket():fill{
			ethType = 0x1234
		}
	end)
	local bufs = mem:bufArray(n)
	ProTable,avgBatchSize = getProTable(n,tau)
	local BatchRate = rate/avgBatchSize
	local rxStats = stats:newDevRxCounter(rxDev, "plain")
	local txStats = stats:newManualTxCounter(dev, "plain")
	local byteDelay = 0
	local num2send = 60*rate*10^6
	while mg.running() do
		bufs:alloc(size)
		pro = math.random();
		sendNum = 0
		for i=1,n do
		    if( pro <= ProTable[i] ) then
			sendNum = i
			break
		    end
		end

		byteDelay = byteDelay +  poissonDelay(10^10 / 8 / (BatchRate * 10^6)) - (size+24)*sendNum -24
		if( byteDelay > 0) then
		    sendn = queue:sendBatchWithDelay(bufs,rate,sendNum,byteDelay)
		    txStats:updateWithSize(sendn, size)
		    rxStats:update()
		    byteDelay = 0
		else
		    txStats:updateWithSize(queue:sendN(bufs,sendNum), size)
                    rxStats:update()
		end
		if( txStats.total > num2send ) then
		    break;
		end
		--txStats:update()
	end
	local rxTimer = timer:new(0.5)
	while rxTimer:running() do
	    rxStats:update()
	end
	mg.stop();

	rxStats:finalize()
	print("Final Recv Packets Num: "..rxStats.total);
	txStats:finalize()
	print("Final Send Packets Num: "..txStats.total);
end

function timerSlave(txQueue, rxQueue, size)
	local timestamper = ts:newTimestamper(txQueue, rxQueue)
	local hist = histogram:new()
	-- wait for a second to give the other task a chance to start
	mg.sleepMillis(1000)
	local rateLimiter = timer:new(0.000001)
	while mg.running() do
		rateLimiter:reset()
		hist:update(timestamper:measureLatency(size))
		rateLimiter:busyWait()
	end
	hist:print()
	hist:save("histogram.csv")
end

