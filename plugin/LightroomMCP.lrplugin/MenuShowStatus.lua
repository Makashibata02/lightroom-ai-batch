local LrDialogs = import 'LrDialogs'

local state = _G.LightroomMCP_State or {}

local lines = {
    LOC("$$$/LightroomAIBatch/Server/Running=Running: ^1", tostring(state.running)),
    LOC("$$$/LightroomAIBatch/Server/RequestConnected=Request socket connected: ^1",
        tostring(state.receiveConnected)),
    LOC("$$$/LightroomAIBatch/Server/ResponseConnected=Response socket connected: ^1",
        tostring(state.sendConnected)),
    LOC("$$$/LightroomAIBatch/Server/LastEvent=Last event: ^1",
        tostring(state.lastEvent or LOC "$$$/LightroomAIBatch/Common/Never=Never")),
    LOC("$$$/LightroomAIBatch/Server/RequestsProcessed=Requests processed: ^1",
        tostring(state.requestsProcessed or 0)),
    "",
    LOC "$$$/LightroomAIBatch/Server/RecentLogs=Recent logs:",
}

if state.log then
    local startIdx = math.max(1, #state.log - 30)
    for i = startIdx, #state.log do
        table.insert(lines, "  " .. state.log[i])
    end
end

LrDialogs.message(
    LOC "$$$/LightroomAIBatch/Server/StatusTitle=Lightroom AI Batch MCP Status",
    table.concat(lines, "\n"),
    "info")
