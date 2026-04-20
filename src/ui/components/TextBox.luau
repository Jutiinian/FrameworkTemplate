--!strict

-- || Services || --
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- || Dependencies || --
local React = require(ReplicatedStorage.Packages.React)

local join = require(ReplicatedStorage.UI.utils.joinDicts)

-- || Constants/Variables || --
local e = React.createElement

-- || Component || --
return function(props: {
	initialText: string?,
	onTextChange: (string) -> ()?,
	maxLength: number?,

	allowNumbers: boolean?,
	allowSpaces: boolean?,
	allowSpecialCharacters: boolean?,

	native: { [string]: any }?,
	children: React.ReactNode?,
}): React.ReactElement
	local currentTextRef = React.useRef(props.initialText)

	React.useEffect(function()
		currentTextRef.current = props.initialText
	end, { props.initialText })

	local sanitize = React.useCallback(function(text: string): string
		if not props.allowNumbers then
			text = text:gsub("%d", "")
		end

		if not props.allowSpaces then
			text = text:gsub("%s", "")
		end

		if not props.allowSpecialCharacters then
			text = text:gsub("[^%w%s]", "")
		end

		return text
	end, { props.allowNumbers, props.allowSpaces, props.allowSpecialCharacters })

	local onTextChange = React.useCallback(function(textBox: TextBox)
		local text = sanitize(textBox.Text)

		if props.maxLength ~= nil and #text > props.maxLength then
			text = text:sub(1, props.maxLength)
		end

		if text ~= textBox.Text then
			textBox.Text = text
		end

		if text == currentTextRef.current then
			return
		end

		-- if props.maxLength ~= nil and #text > props.maxLength then
		-- 	textBox.Text = text:sub(1, props.maxLength)
		-- 	return
		-- end

		currentTextRef.current = text

		if props.onTextChange ~= nil then
			props.onTextChange(text)
		end
	end, { props.onTextChange, props.maxLength or 0, sanitize } :: { unknown })

	return e(
		"TextBox",
		join({
			Text = props.initialText or "",
			[React.Change.Text] = onTextChange,
		}, props.native),
		props.children
	)
end
