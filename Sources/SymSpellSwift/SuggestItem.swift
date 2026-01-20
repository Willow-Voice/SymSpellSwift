//
// SuggestItem.swift
// SymSpellSwift
//
// Created by Gabor Detari gabor@detari.dev
// Copyright (c) 2024 Gabor Detari. All rights reserved.
//

import Foundation

/// Spelling suggestion returned from lookup
public struct SuggestItem: Comparable, Hashable {
    /// The suggested correctly spelled word
    public var term = ""
    /// Edit distance between searched for word and suggestion.
    public var distance = 0
    /// Frequency of suggestion in the dictionary (a measure of how common the word is)
    public var count = 0

    /// Public initializer
    public init(term: String = "", distance: Int = 0, count: Int = 0) {
        self.term = term
        self.distance = distance
        self.count = count
    }

    public static func < (lhs: SuggestItem, rhs: SuggestItem) -> Bool {
        lhs.distance == rhs.distance ? lhs.count > rhs.count: lhs.distance < rhs.distance
    }

    public static func == (lhs: SuggestItem, rhs: SuggestItem) -> Bool {
        lhs.term == rhs.term
    }
}
