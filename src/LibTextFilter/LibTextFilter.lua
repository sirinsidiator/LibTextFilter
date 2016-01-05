local lib = LibStub:NewLibrary("LibTextFilter", 999) -- only for test purposes. releases will get a smaller number

if not lib then
	return	-- already loaded and no upgrade necessary
end
-- support the following commands:
-- space, & => and (default)
-- +, | => or
-- -, ^ => exclude
-- ~ => compare itemID instead of full link (for item links only)
-- () => change operator precedence

-- and: find all words in dataset -> true if each word is found at least once, false otherwise
-- or: find any word in dataset -> true if first word is found, false if no word is found
-- exclude: find any word in dataset and prevent inclusion -> false if first word is found, true if no word is found
-- itemlink: compare like a word
-- ~itemlink: compare only id

lib.RESULT_OK = 1
lib.RESULT_INVALID_ARGUMENT_COUNT = 2
lib.RESULT_INVALID_VALUE_COUNT = 3

local function Convert(input, value)
	if(type(value) == "string") then
		return (input:find(value) ~= nil)
	end
	return value
end

local OPERATORS = {
	[" "] = { precedence = 1, numArguments = 2, operation = function(input, a, b)
		a = Convert(input, a)
		b = Convert(input, b)
		return (a and b)
	end, defaultArgument = true },
	["+"] = { precedence = 1, numArguments = 2, operation = function(input, a, b)
		a = Convert(input, a)
		b = Convert(input, b)
		return (a or b)
	end, defaultArgument = false },
	["-"] = { precedence = 2, isLeftAssociative = false, numArguments = 1, operation = function(input, a)
		return not Convert(input, a)
	end },
	["~"] = { precedence = 3, isLeftAssociative = false, numArguments = 1, operation = function(a) return false end },
	["("] = { isLeftParenthesis = true }, -- control operator
	[")"] = { isRightParenthesis = true }, -- control operator
	["\""] = {}, -- control operator, will be filtered before parsing
}
local OPERATOR_PATTERN = {}
for token, data in pairs(OPERATORS) do
	data.token = token
	OPERATOR_PATTERN[#OPERATOR_PATTERN + 1] = token:gsub("[-*+?^$().[%]%%]", "%%%0") -- escape meta characters
end
OPERATOR_PATTERN = table.concat(OPERATOR_PATTERN, "|")
local TOKEN_DUPLICATION_PATTERN = string.format("([%s])", OPERATOR_PATTERN)
local TOKEN_MATCHING_PATTERN = string.format("([%s])(.-)[%s]", OPERATOR_PATTERN, OPERATOR_PATTERN)
lib.OPERATORS = OPERATORS

function lib:Tokenize(input)
	input = " " .. input:gsub(TOKEN_DUPLICATION_PATTERN, "%1%1") .. " "
	local tokens = {}
	local inQuotes = false
	local lastTerm, lastOperator
	for operator, term in (input):gmatch(TOKEN_MATCHING_PATTERN) do
		--		print(string.format("'%s' '%s'", operator, term))
		if(operator == "\"") then
			inQuotes = not inQuotes
			if(inQuotes) then
				lastTerm = term
			else
				if(lastTerm ~= "") then
					tokens[#tokens + 1] = lastOperator or " "
					tokens[#tokens + 1] = lastTerm
				end
				lastOperator = nil

				if(term ~= "") then
					tokens[#tokens + 1] = " "
					tokens[#tokens + 1] = term
				end
			end
		elseif(inQuotes) then -- collect all terms and operators
			lastTerm = lastTerm .. operator .. term
		else
			if(operator == "(" or operator == ")") then
				tokens[#tokens + 1] = lastOperator
				lastOperator = nil
			elseif(OPERATORS[operator].isLeftAssociative == false and not lastOperator and operator ~= "-") then
				lastOperator = " "
			end
			if(term ~= "") then
				if(operator == "-" and #tokens > 0 and not lastOperator) then
					tokens[#tokens] = tokens[#tokens] .. operator .. term
				else
					if(OPERATORS[operator].isLeftAssociative == false) then
						tokens[#tokens + 1] = lastOperator
						lastOperator = nil
					end
					tokens[#tokens + 1] = operator
					tokens[#tokens + 1] = term
				end
			elseif(OPERATORS[operator].isLeftAssociative == false) then
				tokens[#tokens + 1] = lastOperator
				tokens[#tokens + 1] = operator
				lastOperator = nil
			else
				lastOperator = operator
			end
		end
	end
	if(inQuotes) then
		tokens[#tokens + 1] = lastOperator
		if(lastTerm ~= "") then
			tokens[#tokens + 1] = lastTerm
		end
	elseif(lastOperator == "(" or lastOperator == ")") then
		tokens[#tokens + 1] = lastOperator
	end
	return tokens
		--			local _, itemLinkData = term:match("|H(.-):(.-)|h(.-)|h")
		--			local isLink = (itemLinkData and itemLinkData ~= "")
end

function lib:Parse(tokens)
	local output, stack = {}, {}
	for i = 1, #tokens do
		local token = tokens[i]
		if(OPERATORS[token]) then
			local operator = OPERATORS[token]
			if(operator.isRightParenthesis) then
				while true do
					local popped = table.remove(stack)
					if(not popped or popped.isLeftParenthesis) then
						break
					else
						output[#output + 1] = popped
					end
				end
			elseif(operator.isLeftParenthesis) then
				stack[#stack + 1] = OPERATORS[token]
			elseif(stack[#stack]) then
				local top = stack[#stack]
				if(top.precedence ~= nil
					and ((operator.isLeftAssociative and operator.precedence <= top.precedence)
					or (not operator.isLeftAssociative and operator.precedence < top.precedence))) then
					output[#output + 1] = table.remove(stack)
				end
				stack[#stack + 1] = OPERATORS[token]
			else
				stack[#stack + 1] = OPERATORS[token]
			end
		else
			output[#output + 1] = token
		end
	end
	while true do
		local popped = table.remove(stack)
		if(not popped) then
			break
		elseif(popped.isLeftParenthesis or popped.isRightParenthesis) then
		--ignore misplaced parentheses
		else
			output[#output + 1] = popped
		end
	end
	return output
end

local function PrintArray(array)
	if(#array > 0) then
		local output = {}
		for i = 1, #array do output[i] = tostring(array[i]) end
		return "{\"" .. table.concat(output, "\", \"") .. "\"}"
	else
		return "{}"
	end
end

local function PrintToken(token)
	if(type(token) == "table" and token.token ~= nil) then
		return "'" .. token.token .. "'"
	else
		return "'" .. tostring(token) .. "'"
	end
end

function lib:Evaluate(haystack, parsedTokens)
	local stack = {}
	if(parsedTokens[#parsedTokens].defaultArgument ~= nil) then -- this prevents the root operation from failing
		table.insert(parsedTokens, 1, parsedTokens[#parsedTokens].defaultArgument)
	end
	for i = 1, #parsedTokens do
		local current = parsedTokens[i]
		if(type(current) == "table" and current.operation ~= nil) then
			if(#stack < current.numArguments) then
				return false, lib.RESULT_INVALID_ARGUMENT_COUNT
			else
				local args = {}
				for j = 1, current.numArguments do
					args[#args + 1] = table.remove(stack)
				end
				stack[#stack + 1] = current.operation(haystack, unpack(args))
			end
		else
			stack[#stack + 1] = current
		end
	end

	if(#stack == 1) then
		return stack[1], lib.RESULT_OK
	else
		return false, lib.RESULT_INVALID_VALUE_COUNT
	end
end

function lib:Filter(haystack, needle)
	local tokens = self:Tokenize(needle)
	local parsedTokens = self:Parse(tokens)
	return self:Evaluate(haystack, parsedTokens)
end