allWords = []
let prevHighlightedEl = document.createElement("dummy")

function splitBodyIntoWords(startWordIdx = 0) {
    if (allWords.length === 0)
        allWords = split(document.body, startWordIdx)
}

function getAllWordsStr(startWordIdx = 0) {
    splitBodyIntoWords(startWordIdx)
    var allWordsStr = []
    allWords.forEach(el => allWordsStr.push(el.innerText))  // TODO: make ASCII conversion here?
    return allWordsStr
}

function countWords(startWordIdx = 0) {
    splitBodyIntoWords(startWordIdx)
    return allWords.length  // TODO: make it more efficient
}

function getSelectedWord() {
    let anchorNode = window.getSelection().anchorNode
    window.getSelection().removeAllRanges() // clear selection
    if (!anchorNode)
        return null
    if (anchorNode.nodeType == 3)  // is a text node (most likely) so get its parent
        anchorNode = anchorNode.parentElement
    if (!anchorNode.id) // no id
        return null
    match = anchorNode.id.match(/^(?:pre\-)?word\-(\d+)$/)
    if (!match)
        return null
    return parseInt(match[1])  // the id group
}

function highlightWordIdx(wordIdx, highlightColor="rgba(255, 255, 0, 0.3)") {
    let newWord = document.getElementById(`word-${wordIdx}`)
    if (!newWord)
        console.log("Error: Word not found")
    newWord.style.background = highlightColor

    if (newWord == prevHighlightedEl)  // asked to highlight the same word, don't unhighlight anything
        return

    prevHighlightedEl.style.background = ""
    prevHighlightedEl = newWord
}

const settings = {
    wordClass: 'word',
    wordGapClass: 'word-gap',
    processedFlagAttribute: 'split-processed',
    absolute: false,
    tagName: 'span',
    wordSeparator: /([^\w\d\p{L}'‘’‛]+)/gu,
}

function split(node, startWordIdx = 0) {
    const type = node.nodeType
    // Arrays of split words and characters
    const words = []

    // Only proceed if `node` is an `Element`, `Fragment`, or `Text`
    if (!/(1|3|11)/.test(type)) {
        return words
    }

    // A) IF `node` is TextNode that contains characters other than white space...
    //    Split the text content of the node into words and/or characters
    //    return an object containing the split word and character elements
    if (type === 3) {
        return splitWords(node, startWordIdx)
    }

    // B) ELSE `node` is an 'Element'
    //    Iterate through its child nodes, calling the `split` function
    //    recursively for each child node.

    // Mark element as processed so that if it's called again it doesn't resplit all the words
    if (node.getAttribute(settings.processedFlagAttribute) != null)
        return words
    node.setAttribute(settings.processedFlagAttribute, "")

    const childNodes = toArray(node.childNodes)

    // Iterate through child nodes, calling `split` recursively
    // Returns an object containing all split words and chars
    return childNodes.reduce((result, child) => {
        const newWords = split(child, startWordIdx)
        startWordIdx += newWords.length
        return [...result, ...newWords]
    }, words)
}

function splitWords(textNode, startWordIdx = 0) {
    // the tag name for split text nodes
    const TAG_NAME = settings.tagName
    // value of the text node
    const VALUE = textNode.nodeValue
    // `splitText` is a wrapper to hold the HTML structure
    const splitText = document.createDocumentFragment()

    // Arrays of split word and character elements
    let words = []
    let wordIdx = startWordIdx
    let isWord = true

    // Create an array of wrapped word elements.
    words = toWords(VALUE).reduce((result, WORD, idx, arr) => {
        if (!WORD.length) {  // first or last element will be empty only if string starts or ends with separator
            isWord = false // so next element is a separator
            return result  // don't add empty element anywhere
        }

        // Let `wordElement` be the wrapped element for the current word
        let wordElement

        // -> If Splitting Text Into Words...
        //    Create an element to wrap the current word. If we are also
        //    splitting text into characters, the word element will contain the
        //    wrapped character nodes for this word. If not, it will contain the
        //    plain text content (WORD)
        if (isWord)
            wordElement = createElement(TAG_NAME, {
                class: settings.wordClass,
                id: `word-${wordIdx}`,
                children: WORD,
            })
        else  // this is a separator so make an element for it too
            wordElement = createElement(TAG_NAME, {
                class: settings.wordGapClass,
                id: `pre-word-${wordIdx}`,
                children: WORD,
            })

        splitText.appendChild(wordElement)

        wordIdx += isWord  // add word index counter if currently dealing with a word

        // if this was a word, next element will be a separator and vice versa, so flip isWord
        return (isWord = !isWord) ? // if this wasn't a word, don't append to result
            result : result.concat(wordElement)
    }, []) // END LOOP;

    textNode.replaceWith(splitText)
    return words
}

function toWords(value) {
    const string = value ? String(value) : ''
    return string.split(settings.wordSeparator)
}

function createElement(name, attributes) {
    const element = document.createElement(name)

    if (!attributes) {
        // When called without the second argument, its just return the result
        // of `document.createElement`
        return element
    }

    Object.keys(attributes).forEach((attribute) => {
        const rawValue = attributes[attribute]
        const value = rawValue
        // Ignore attribute if the value is `null` or an empty string
        if (value === null || value === '') return
        if (attribute === 'children') {
            // Children can be one or more Elements or DOM strings
            element.append(...toArray(value))
        } else {
            // Handle standard HTML attributes
            element.setAttribute(attribute, value)
        }
    })
    return element
}

function isString(value) {
    return typeof value === 'string'
}

function toArray(value) {
    if (isArray(value)) return value
    if (value == null) return []
    return isArrayLike(value) ? Array.prototype.slice.call(value) : [value]
}

function isArray(value) {
    return Array.isArray(value)
}

function isArrayLike(value) {
    return isObject(value) && isLength(value.length)
}

function isObject(value) {
    return value !== null && typeof value === 'object'
}

function isLength(value) {
    return typeof value === 'number' && value > -1 && value % 1 === 0
}