local HandlerBatch = {}

local function pipeline()
    return require 'BatchPipeline'
end

function HandlerBatch.start(args)
    return pipeline().start(args or {})
end

function HandlerBatch.status(args)
    return pipeline().status(args or {})
end

function HandlerBatch.cancel(args)
    return pipeline().cancel(args or {})
end

return HandlerBatch
